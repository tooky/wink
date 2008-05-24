require 'net/http'
require 'akismet'

class Entry
  include DataMapper::Persistence

  property :slug, :string, :size => 255, :nullable => false
  property :type, :class, :nullable => false
  property :published, :boolean, :default => false
  property :title, :string, :size => 255, :nullable => false
  property :summary, :text, :lazy => false
  property :filter, :string, :size => 20, :default => 'markdown'
  property :url, :string, :size => 255
  property :created_at, :datetime, :nullable => false
  property :updated_at, :datetime, :nullable => false
  property :body, :text

  index [ :slug ], :unique => true
  index [ :type ]
  index [ :created_at ]

  #validates_presence_of :title, :slug, :filter

  has_many :comments,
    :spam.not => true,
    :order => 'created_at ASC'

  has_and_belongs_to_many :tags,
    :join_table => 'taggings'

  def stem
    "writings/#{slug}"
  end

  def permalink
    "#{Weblog.url}/#{stem}"
  end

  def domain
    if url && url =~ /https?:\/\/([^\/]+)/
      $1.strip.sub(/^www\./, '')
    end
  end

  def created_at
    @created_at ||= Time.now
  end

  def filter
    @filter ||= 'markdown'
  end

  def published?
    [1,true].include?(published)
  end

  def draft?
    ! published?
  end

  def body?
    ! body.empty?
  end

  def tag_names=(value)
    tags.clear
    tag_names =
      if value.respond_to?(:to_ary)
        value.to_ary
      elsif value.respond_to?(:to_str)
        value.gsub(/[\s,]+/, ' ').split(' ').uniq
      end
    tag_names.each do |tag_name|
      tag = Tag.find_or_create(:name => tag_name)
      tags << tag
    end
  end

  def tag_names
    tags.collect { |t| t.name }
  end

  def publish=(value)
    value = ['Publish', '1', 'true', 'yes'].include?(value.to_s)
    self.created_at = self.updated_at = Time.now if value && draft?
    self.published = value
  end

  # This shouldn't be necessary but DM isn't adding the type condition.
  def self.all(options={})
    return super if self == Entry
    options = { :type => ([self] + self::subclasses.to_a) }.
      merge(options)
    super(options)
  end

  def self.published(options={})
    options = { :order => 'created_at DESC', :published => true }.
      merge(options)
    all(options)
  end

  def self.published_circa(year, options={})
    options = {
      :created_at.gte => Date.new(year, 1, 1),
      :created_at.lt => Date.new(year + 1, 1, 1),
      :order => 'created_at ASC'
    }.merge(options)
    published(options)
  end

  def self.drafts(options={})
    options = { :order => 'created_at DESC', :published => false }.
      merge(options)
    all(options)
  end

  def self.tagged(tag, options={})
    if tag = Tag.first(:name => tag)
      tag.entries
    else
      []
    end
  end

end

class Article < Entry
end

class Bookmark < Entry

  def stem
    "linkings/#{slug}"
  end

  def filter
    'markdown'
  end

  # The Time of the most recently updated Bookmark in UTC.
  def self.last_updated_at
    latest = first(:order => 'created_at DESC', :type => 'Bookmark')
    # NOTE: we take DateTime through an ISO8601 string on purpose to maintain
    # timezone info. DateTime#to_time does not work properly.
    Time.iso8601(latest.created_at.strftime("%FT%T%Z"))
  end

  def self.synchronize(options={})
    delicious = self.delicious.dup
    options.each { |key,val| delicious.send("#{key}=", val) }
    count = 0
    delicious.synchronize :since => last_updated_at do |source|
      next if source[:href] =~ Weblog.url_regex
      next unless source[:shared]
      bookmark = find_or_create(:slug => source[:hash])
      bookmark.attributes = {
        :url        => source[:href],
        :title      => source[:description],
        :summary    => source[:extended],
        :body       => source[:extended],
        :filter     => 'text',
        :created_at => source[:time].getlocal,
        :updated_at => source[:time].getlocal,
        :published  => 1
      }
      bookmark.tag_names = source[:tags]
      bookmark.save
      count += 1
    end
    count
  end

end


class Tag
  include DataMapper::Persistence

  property :name, :string, :nullable => false
  property :created_at, :datetime, :nullable => false
  property :updated_at, :datetime, :nullable => false

  index [ :name ], :unique => true

  has_and_belongs_to_many :entries,
    :conditions => { :published => true },
    :order => "(entries.type = 'Bookmark') ASC, entries.created_at DESC",
    :join_table => 'taggings'

  def to_s
    name
  end
end

class Tagging
  include DataMapper::Persistence

  belongs_to :entry
  belongs_to :tag
  index [ :entry_id ]
  index [ :tag_id ]
end

class Comment
  include DataMapper::Persistence

  property :author, :string, :size => 80
  property :ip, :string, :size => 50
  property :url, :string, :size => 255
  property :body, :text
  property :created_at, :datetime, :nullable => false
  property :referrer, :string, :size => 255
  property :user_agent, :string, :size => 255
  property :checked, :boolean, :default => false
  property :spam, :boolean, :default => false

  belongs_to :entry

  index [ :entry_id ]
  index [ :spam ]
  index [ :created_at ]

  #validates_presence_of :body
  #validates_presence_of :entry_id

  before_create do |comment|
    comment.check
    true
  end

  def self.ham(options={})
    all({:spam.not => true, :order => 'created_at DESC'}.merge(options))
  end

  def self.spam(options={})
    all({:spam => true, :order => 'created_at DESC'}.merge(options))
  end

  def excerpt(length=65)
    body.to_s.gsub(/[\s\r\n]+/, ' ')[0..65] + " ..."
  end

  def body_with_links
    body.to_s.
      gsub(/(^|[\s\t])(www\.\S+)/, '\1<http://\2>').
      gsub(/(?:^|[^\]])\((https?:\/\/[^)]+)\)/, '<\1>').
      gsub(/(^|[\s\t])(https?:\/\/\S+)/, '\1<\2>').
      gsub(/^(\s*)(#\d+)/) { [$1, "\\", $2].join }
  end

  def spam?
    spam
  end

  def ham?
    ! spam?
  end

  def check
    @checked = true
    @spam = check_comment
  rescue ::Net::HTTPError => boom
    logger.error "An error occured while connecting to Akismet: #{boom.to_s}"
    @checked = false
  end

  def check!
    check
    save!
  end

  def spam!
    @spam = true
    submit_spam
    save!
  end

  def url
    if @url.to_s.strip.blank?
      nil
    else
      @url.strip
    end
  end

  def author_link
    case url
    when nil                         then nil
    when /^mailto:.*@/, /^https?:.*/ then url
    when /@/                         then "mailto:#{url}"
    else                                  "http://#{url}"
    end
  end

  def author_link?
    !author_link.nil?
  end

  def author
    if @author.blank?
      'Anonymous Coward'
    else
      @author
    end
  end

private

  def akismet_params(others={})
    { :user_ip            => ip,
      :user_agent         => user_agent,
      :referrer           => referrer,
      :permalink          => entry.permalink,
      :comment_type       => 'comment',
      :comment_author     => author,
      :comment_author_url => url,
      :comment_content    => body }.merge(others)
  end

  def check_comment(params=akismet_params)
    if production?
      self.class.akismet.check_comment(params)
    else
      false
    end
  end

  def submit_spam(params=akismet_params)
    self.class.akismet.submit_spam(params)
  end

  # Wipe out the akismet singleton every 10 minutes due to suspected leaks.
  def self.akismet
    @akismet = Akismet::new(Weblog.akismet, Weblog.url) if @akismet.nil? || (akismet_age > 600)
    @last_akismet_access = Time.now
    @akismet
  end

  def self.akismet_age
    Time.now - @last_akismet_access
  end

end
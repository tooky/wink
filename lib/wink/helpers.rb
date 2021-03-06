require 'wink/markdown'

module Wink::Helpers
  include Rack::Utils
  alias :h :escape_html

  # Sanitize HTML - removes potentially dangerous markup like <script> and
  # <object> tags.
  def sanitize(html)
    HTML5::HTMLParser.
      parse_fragment(html, :tokenizer => HTML5::HTMLSanitizer, :encoding => 'utf-8').
      to_s
  end

  # Convert text to HTML using Markdown (includes text smartification). Uses
  # RDiscount if available and falls back to BlueCloth.
  def markdown(text)
    return '' if text.nil? || text.empty?
    Wink::Markdown.new(text, :smart).to_html
  end

  # Make text "smart" by converting dumb puncuation characters to their
  # high-class equivalents.
  def smartify(text)
    return '' if text.nil? || text.empty?
    RubyPants.new(text).to_html
  end

  # Apply a list of content filters to text. Calls each helper method in
  # the order specified with the result of the previous operation. The following
  # are equivalent:
  #
  #   filter "Hello, World.", :markdown, :sanitize
  #   sanitize(markdown("Hello, World."))
  #
  def filter(text, *filters)
    filters.inject(text) do |text,method_name|
      send(method_name, text)
    end
  rescue => boom
    "<p><strong>Boom!</strong></p><pre>#{escape_html(boom.to_s)}</pre>"
  end

  def html(text)
    text || ''
  end

  # The comment's formatted body.
  def comment_body(comment=@comment)
    filter(comment.body, *Wink.comment_filters)
  end

  # The entry's formatted body.
  def entry_body(entry=@entry)
    filter(entry.body, entry.filter)
  end

  # The entry's formatted summary.
  def entry_summary(entry=@entry)
    filter(entry.summary, :markdown)
  end

  # The entry's persistent, globally unique identifier; used primarily in
  # feeds. Defaults to the entry's permalink (#entry_url). See also:
  # http://diveintomark.org/archives/2004/05/28/howto-atom-id
  def entry_global_id(entry=@entry)
    entry_url(entry)
  end

  # The comment's persistent, globally unique identifier; used primarily in
  # feeds. Defaults to the comment's url (#comment_url). See also:
  # http://diveintomark.org/archives/2004/05/28/howto-atom-id
  def comment_global_id(comment=@comment)
    comment_url(comment)
  end

  # Convert hash to HTML attribute string.
  def attributes(*attrs)
    return '' if attrs.empty?
    attrs.inject({}) { |attrs,hash| attrs.merge(hash) }.
      reject { |k,v| v.nil? }.
      collect { |k,v| "#{k}='#{h(v)}'" }.
      join(' ')
  end

  # When content is nil, tag is non-closing (<foo>); when content is
  # an empty string, tag is self-closed (<foo />); all other values
  # create a normal content tag (<foo>BAR</foo>). All attribute values
  # are html escaped. The content value is NOT escaped.
  def tag(name, content, *attrs)
  [
    "<#{name}",
    (" #{attributes(*attrs)}" if attrs.any?),
    (case content
     when nil then '>'
     else ">#{content}</#{name}>"
     end)
  ].compact.join
  end

  def timestamp!(path)
    return path if path =~ /http:/
    file = File.join(wink.public, path)
    if mtime = (File.mtime(file) rescue nil)
      path[path.length,0] = '?' + mtime.to_i.to_s
    end
    path
  end

  def timestamp(path)
    path.dup.timestamp!
  end

  def feed(href, title)
    tag :link, nil,
      :rel => 'alternate',
      :type => 'application/atom+xml',
      :title => title,
      :href => href
  end

  def css(href, media='all')
    href = "/css/#{href}.css" unless href =~ /\.css$/
    timestamp! href
    tag :link, nil,
      :rel => 'stylesheet',
      :type => 'text/css',
      :href => href,
      :media => media
  end

  # When src is a single word, assume it is an external resource and
  # use `<script src=`; otherwise, embed script in tag.
  def script(src)
    if src =~ /\s/
      %(<script type='text/javascript'>#{src}</script>)
    else
      src = "/js/#{src}.js" unless src =~ /\.js$/
      timestamp! src
      %(<script type='text/javascript' src='#{src}'></script>)
    end
  end

  def href(text, url, *attrs)
    tag :a, h(text), { :href => url }, *attrs
  end

  def root_url(*args)
    [ wink.url, *args ].compact.join("/")
  end

  def entry_url(entry)
    entry.url || Wink.writings_url + entry.slug
  end

  def entry_ref(entry, text=entry.title, *attrs)
    href(text, entry_url(entry), *attrs)
  end

  def draft_url(entry)
    Wink.drafts_url + entry.slug
  end

  def draft_ref(entry, text, *attrs)
    href(text, draft_url(entry), *attrs)
  end

  def topic_url(tag)
    Wink.tag_url + tag.to_s
  end

  def topic_ref(tag)
    href(tag.to_s, topic_url(tag))
  end

  def comment_url(comment)
    "#{entry_url(comment.entry)}#comment-#{comment.id}"
  end

  def input(type, name, value=nil, *attrs)
    tag :input, nil,
      { :id => name, :name => name, :type => type.to_s, :value => value },
      *attrs
  end

  def textbox(name, value=nil)
    input :text, name, value
  end

  def textarea(name, value, *attrs)
    tag :textarea, h(value || ''), { :name => name, :id => name }, *attrs
  end

  def selectbox(name, value, options)
    options.inject("<select name='#{name}' id='#{name}'>") { |m,(k,v)|
      m << "<option value='#{h(k)}'#{v == value && ' selected' || ''}>#{h(v)}</option>"
    } << "</select>"
  end

  # Write a debug/trace message to the log
  def trace(message, *params)
    return unless wink.verbose
    message = message % params unless params.empty?
    request.env['rack.errors'].puts "[wink] trace: #{message}"
  end

  def wink
    Wink
  end

end

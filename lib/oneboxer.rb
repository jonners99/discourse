require 'open-uri'
require 'digest/sha1'

require_dependency 'oneboxer/base'
require_dependency 'oneboxer/whitelist'
Dir["#{Rails.root}/lib/oneboxer/*_onebox.rb"].each {|f|
  require_dependency(f.split('/')[-2..-1].join('/'))
}

module Oneboxer
  extend Oneboxer::Base

  Dir["#{Rails.root}/lib/oneboxer/*_onebox.rb"].sort.each do |f|
    add_onebox "Oneboxer::#{Pathname.new(f).basename.to_s.gsub(/\.rb$/, '').classify}".constantize
  end

  def self.default_expiry
    1.day
  end

  # Return a oneboxer for a given URL
  def self.onebox_for_url(url)
    matchers.each do |matcher|
      regexp = matcher.regexp
      klass = matcher.klass

      regexp = regexp.call if regexp.class == Proc
      return klass.new(url) if url =~ regexp
    end
    nil
  end

  # Retrieve the onebox for a url without caching
  def self.onebox_nocache(url)
    oneboxer = onebox_for_url(url)
    return oneboxer.onebox if oneboxer.present?

    whitelist_entry = Whitelist.entry_for_url(url)

    if whitelist_entry.present?
      page_html = open(url).read
      if page_html.present?
        doc = Nokogiri::HTML(page_html)

        if whitelist_entry.allows_oembed?
          # See if if it has an oembed thing we can use
          (doc/"link[@type='application/json+oembed']").each do |oembed|
            return OembedOnebox.new(oembed[:href]).onebox
          end
          (doc/"link[@type='text/json+oembed']").each do |oembed|
            return OembedOnebox.new(oembed[:href]).onebox
          end
        end

        # Check for opengraph
        open_graph = Oneboxer.parse_open_graph(doc)
        return OpenGraphOnebox.new(url, open_graph).onebox if open_graph.present?
      end
    end

    nil
  rescue OpenURI::HTTPError
    nil
  end

  # Parse URLs out of HTML, returning the document when finished.
  def self.each_onebox_link(string_or_doc)
    doc = string_or_doc
    doc = Nokogiri::HTML(doc) if doc.is_a?(String)

    onebox_links = doc.search("a.onebox")
    if onebox_links.present?
      onebox_links.each do |link|
        if link['href'].present?
          yield link['href'], link
        end
      end
    end

    doc
  end

  def self.cache_key_for(url)
    "onebox:#{Digest::SHA1.hexdigest(url)}"
  end

  def self.render_from_cache(url)
    Rails.cache.read(cache_key_for(url))
  end

  # Cache results from a onebox call
  def self.fetch_and_cache(url, args)
    contents = onebox_nocache(url)
    return nil if contents.blank?

    Rails.cache.write(cache_key_for(url), contents, expires_in: default_expiry)
    contents
  end

  def self.invalidate(url)
    Rails.cache.delete(cache_key_for(url))
  end

  # Return the cooked content for a url, caching the result for performance
  def self.onebox(url, args={})

    if args[:invalidate_oneboxes]
      # Remove the onebox from the cache
      Oneboxer.invalidate(url)
    else
      contents = render_from_cache(url)
      return contents if contents.present?
    end

    fetch_and_cache(url, args)
  end

end

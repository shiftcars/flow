require 'fileutils'
require 'json'
require 'open3'
require 'set'
require 'tmpdir'

module Jekyll
  EXT = ".doc.js"
  EXT_REGEX = /\.doc\.js$/i
  YAML_REGEX = /^(---\s*\n.*?\n?)^((---|\.\.\.)\s*$\n?)/m

  class FlowdocGenerator < Generator
    priority :low

    def generate(site)
      site.static_files.delete_if do |sf|
        next if not sf.path =~ EXT_REGEX

        dirname = File.dirname(sf.path.gsub(site.source, ""))
        basename = File.basename(sf.path)

        site.pages << FlowdocPage.new(site, site.source, dirname, basename)

        true
      end
    end
  end

  class FlowdocPage < Page
    def process(name)
      self.ext = EXT
      self.basename = name[0..-ext.length - 1]
    end

    def read_yaml(base, name, opts = {})
      filename = File.join(base, name)

      begin
        self.content = File.read(site.in_source_dir(base, name),
                                 Utils.merged_file_read_opts(site, opts))
        if content =~ YAML_REGEX
          self.data = SafeYAML.load(Regexp.last_match(1))
        end
      rescue Exception => e
        Jekyll.logger.warn "Error reading file #{filename}: #{e.message}"
      end

      self.data ||= {}

      validate_data! filename
      validate_permalink! filename

      self.data
    end
  end

  class FlowdocConverter < Converter
    class << self
      attr_accessor :tempdir

      def valid_pragma?(str)
        @pragmas ||= Set.new ['$WithLineNums']
        @pragmas.include? str
      end
    end

    def initialize(config = {})
      super(config)
      @markdown = Converters::Markdown.new @config
    end

    def matches(ext)
      ext =~ EXT_REGEX
    end

    def output_ext(ext)
      '.html'
    end

    def convert_token(token)
      type, range, context = token.values_at('type', 'range', 'context')
      if type == 'T_EOF'
        {
          :value => "",
          :range => range
        }
      else
        {
          :start => "<span class=\"#{context} #{type}\">",
          :end => "</span>",
          :range => range
        }
      end
    end

    def is_block_comment(comment)
      comment['type'] == 'Block' && comment['loc']['start']['column'] == 0
    end

    def is_ignored_comment(comment)
      loc, value = comment.values_at('loc', 'value')
      start = loc['start']
      is_block_comment(comment) &&
        ((start['line'] == 1 && value.strip == "@flow") || value =~ YAML_REGEX)
    end

    def is_pragma(comment)
      comment['loc']['start']['column'] == 0 &&
        self.class.valid_pragma?(comment['value'].strip)
    end

    def unindent(str)
      str = str.gsub(/\A\n|\n\z/m, '')
      indent = str.gsub(/\n+/m, "\n").scan(/^[ \t]*/).min_by { |l| l.length }
      str.gsub!(/^#{indent}/, "")
    end

    def convert_comment(comment)
      type, loc, value, range = comment.values_at('type', 'loc', 'value', 'range')
      if is_ignored_comment(comment)
        {
          :value => "",
          :range => range
        }
      elsif is_pragma(comment)
        {
          :pragma => value.strip,
          :range => range
        }
      elsif is_block_comment(comment)
        {
          :value => @markdown.convert(unindent(value)),
          :range => range
        }
      else
        {
          :start => '<span class="comment %s">' % [type.downcase],
          :end => '</span>',
          :range => range
        }
      end
    end

    def flow_exe
      @config['flow']['path'] || 'flow'
    end

    def get_tokens(content)
      token_json = Open3.popen3("#{flow_exe} ast --tokens") {|stdin, stdout|
        stdin.puts(content)
        stdin.close
        JSON.parse(stdout.gets)
      }
      tokens, errors, comments = token_json.values_at('tokens', 'errors', 'comments')
      tokens = tokens.map {|token| convert_token token }
      items = comments.reduce(tokens) do |comments, comment|
        comments.push(convert_comment(comment))
        comments
      end
    end

    def get_error_json(content)
      cmd = "#{flow_exe} check-contents --json --root #{self.class.tempdir}"
      response = Open3.popen3(cmd) {|stdin, stdout|
        stdin.puts(content)
        stdin.close
        JSON.parse(stdout.gets)
      }

      errors_json = response['errors']

      line_lengths = content.lines.map { |line| line.length }
      line_offsets = [0]
      line_lengths.each_with_index do |line_length, index|
        line_offsets[index + 1] = line_offsets[index] + line_length
      end

      errors = []
      errors_json.each_with_index do |error, e_index|
        e_id = e_index + 1
        messages = []
        error['message'].each_with_index do |message, m_index|
          m_id = e_id * 1000 + (m_index + 1)
          msg_json = {
            'id' => "M#{m_id}",
            'description' => message['descr']
          }

          m_loc = message['loc']
          if m_loc != nil
            start_line, start_col = m_loc.values_at('line', 'start')
            end_line, end_col = m_loc.values_at('endline', 'end')

            if start_line && start_line > 0 && end_line && end_line > 0
              start_offset = line_offsets[start_line - 1] + start_col - 1
              end_offset = line_offsets[end_line - 1] + end_col

              msg_json['start'] = {
                'line' => start_line,
                'column' => start_col,
                'offset' => start_offset
              }
              msg_json['end'] = {
                'line' => end_line,
                'column' => end_col + 1,
                'offset' => end_offset
              }
            end
          end

          messages.push(msg_json)
        end
        errors.push({
          'id' => "E#{e_id}",
          'messages' => messages
        })
      end
      errors
    end

    def get_errors(errors_json)
      errors_json.reduce([]) do |errors, error|
        e_id = error['id']
        error['messages'].each do |message|
          next unless message.has_key?('start') && message.has_key?('end')

          start_offset = message['start']['offset']
          end_offset = message['end']['offset']
          errors.push({
            :start =>
              "<span " +
                "class=\"error\"" +
                "data-error-id=\"#{e_id}\" " +
                "data-message-id=\"#{message['id']}\">",
            :end => '',
            :range => [start_offset, start_offset],
            :length => end_offset - start_offset
          })
          errors.push({
            :start => '',
            :end => '</span>',
            :range => [end_offset, end_offset]
          })
        end
        errors
      end
    end

    def escape(str)
      CGI.escapeHTML(str).untaint
    end

    def convert(content)
      content = content.lines.reject { |l|
        l =~ /^\s*\/\/\s*\$ExpectError(\([^)]*\))?$/
      }.join
      tokens = get_tokens(content)
      errors_json = get_error_json(content)
      errors = get_errors(errors_json)
      items = (tokens + errors).sort_by {|item|
        # sort by position, then by :length (longest to shortest), which sorts
        # the opening <span> tags on errors.
        [item[:range], -1 * (item[:length] || 0)
      ]}
      sections = []
      out = ""
      pragmas = Set.new
      last_loc = 0
      last_was_code = false
      items.each do |item|
        start_loc, end_loc = item[:range]
        is_code = !item.has_key?(:value)
        if last_was_code && !is_code
          sections.push([
            pragmas.include?('$WithLineNums') ? :code_with_nums : :code,
            out.sub(/\A\n+|\n+\z/m, '')
          ])
          out = ""
          pragmas.clear()
        elsif !last_was_code && is_code
          sections.push([:html, out])
          out = ""
          pragmas.clear()
        end

        if item.has_key?(:pragma)
          pragmas.add(item[:pragma])
          last_loc = end_loc # skip the pragma
          last_was_code = true
          next
        end

        # Catch up over whitespace
        out += escape(content.slice(last_loc, start_loc - last_loc))

        if !is_code
          out += item[:value]
          last_was_code = false
        else
          out += item[:start]
          out += escape(content.slice(start_loc, end_loc - start_loc))
          out += item[:end]
          last_was_code = true
        end
        last_loc = end_loc
      end
      out += escape(content.slice(last_loc, content.length - last_loc))
      sections.push([last_was_code ? :code : :html, out])

      outs = sections.map do |type, content|
        content = content.lines.reject { |l|
          l =~ /\/\/\s*\$Doc(Issue|Hide)/
        }.join
        if type == :code_with_nums
          lines = content.lines.count
          '<figure class="highlight">' +
            '<table class="highlighttable" style="border-spacing: 0"><tbody><tr>' +
              '<td class="gutter gl" style="text-align: right">' +
                '<pre class="lineno">' +
                  (1..lines).to_a.join("\n") +
                '</pre>' +
              '</td>' +
              '<td class="code"><pre>' + content + '</pre></td>' +
            '</tr></tbody></table>' +
          '</figure>'
        elsif type == :code
          '<figure class="highlight">' +
            '<pre><code>' + content + '</code></pre>' +
          '</figure>'
        else
          content
        end
      end

      out = outs.join
      out += '<script src="//code.jquery.com/jquery-git2.min.js"></script>'
      out += '<script src="/static/dhtml.js"></script>'
      out += "<script>highlightErrors(#{JSON.generate(errors_json)})</script>"
      out
    end
  end

  Hooks.register :site, :pre_render do |site|
    FlowdocConverter.tempdir = Dir.mktmpdir
    File.open(File.join(FlowdocConverter.tempdir, '.flowconfig'), 'w') {|f|
      f.write("[options]\nsuppress_comment=\\\\(.\\\\|\\n\\\\)*\\\\$DocIssue\n")
    }
  end

  Hooks.register :site, :post_render do |site|
    flow = site.config['flow']['path'] || 'flow'
    `#{flow} stop #{FlowdocConverter.tempdir}`
    FileUtils.remove_entry_secure FlowdocConverter.tempdir
  end

end

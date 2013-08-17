class DocsetGenerator
  require 'rubygems'
  require 'nokogiri'
  require 'fileutils'

  def sanitize(str)
    str.to_s.gsub(/\n/, ' ')
  end

  def parse_html_docref(node)
    code = ''
    code << node.xpath(".//p[@class='abstract']").text
    code << "\n"

    node_discussion = node.xpath(".//div[@class='api discussion']")
    node_cdesample  = node_discussion.xpath(".//div[@class='codesample clear']")
    node_cdesample.unlink

    code << node_discussion.text.sub(/^Discussion/, '')
    code.strip!
    code.gsub!(/^/m, '  # ')
    code << "\n"
    return code
  end

  def parse_type(type)
    if type.kind_of?(Array)
      type = type.first
    end
    type = type.to_s
    type.strip!
    star = type.sub!(/\s*\*$/, '') # Remove pointer star.
    case type
      when /\*$/
        # A double pointer, in MacRuby this becomes a Pointer.
        'Pointer'
      when /id(?:\s*<\w+>)?/
        'Object'
      when 'void'
        'nil'
      when 'SEL'
        'Symbol'
      when 'bool', 'BOOL'
        'Boolean'
      when 'float', 'double', 'CGFloat'
        'Float'
      when /^(?:const\s+)?u?int(?:\d+_t)?/, 'char', 'unichar', 'short', 'long', 'long long', 'unsigned char', 'unsigned short', 'unsigned long', 'unsigned long long', 'NSInteger', 'NSUInteger'
        'Integer'
      when 'NSString', 'NSMutableString'
        'String'
      when 'NSArray', 'NSMutableArray'
        'Array'
      when 'NSDictionary', 'NSMutableDictionary'
        'Hash'
      else
        type
    end
  end

  def parse_html_property(doc, code = "")
    # Properties.
    doc.xpath("//div[@class='api propertyObjC']").each do |node|
      decl = node.xpath(".//div[@class='declaration']/div[@class='declaration']").text
      if decl.length == 0
        decl = node.xpath(".//div[@class='declaration']").text
      end
      readonly = decl.include?('readonly')
      decl.sub!(/@property\s*(\([^\)]+\))?/, '')
      md = decl.match(/(\w+);?$/)
      next unless md
      title = md[1]
      type = md.pre_match

      code << parse_html_docref(node)
      code << "  # @return [#{parse_type(type)}]\n"
      code << '  ' << (readonly ? "attr_reader" : "attr_accessor") << " :#{title}\n\n"
    end

    return code
  end

  def parse_html_method(doc, code = "")
    # Methods.
    methods = []
    methods.concat(doc.xpath("//div[@class='api classMethod']"))
    methods.concat(doc.xpath("//div[@class='api instanceMethod']"))
    methods.each do |node|
      decl = node.xpath(".//div[@class='declaration']").text
      types = decl.scan(/\(([^)]+)\)/)
      ret_type = types.shift

      # Docref.
      code << parse_html_docref(node)

      # Parameters and return value.
      arg_names = node.xpath(".//div[@class='api parameters']//dt")
      arg_docs = node.xpath(".//div[@class='api parameters']//dd")
      if arg_names.size == arg_docs.size
        has_types = types.size == arg_names.size
        arg_names.each_with_index do |arg_name, i|
          arg_doc = arg_docs[i]
          code << "  # @param "
          code << "[#{parse_type(types[i])}] " if has_types
          code << "#{arg_name.text} #{sanitize(arg_doc.text)}\n"
        end
      end
      retdoc = node.xpath(".//div[@class='return_value']/p").text.strip
      code << "  # @return "
      code << "[#{parse_type(ret_type)}] " if ret_type
      code << "#{sanitize(retdoc)}" unless retdoc.empty?
      code << "\n"

      is_class_method = decl.match(/^\s*\+/) != nil
      code << "  # @scope class\n" if is_class_method

      decl.sub!(/^\s*[\+\-]/, '') # Remove method qualifier.
      decl.sub!(/;\s*$/, '')

      no_break_space = [0x00A0].pack("U*")
      decl.gsub!(no_break_space, '')

      sel_parts = decl.gsub(/\([^)]+\)+/, '').split.map { |x| x.split(':') }
      head = sel_parts.shift
      code << "  def #{head[0]}("
      code << "#{head[1]}" if head.size > 1
      unless sel_parts.empty?
        code << ', '
        code << sel_parts.map { |part|
          if part[1]
            "#{part[0]}:#{part[1]}"
          else
            part[0]
          end
        }.join(', ')
      end
      code << "); end\n\n"
    end

    return code
  end

  def parse_html_constant(doc, code_const = "", code_struct = "")
    doc.xpath("//div[@id='Constants_section']").each do |node|
      node_abstract    = node.xpath("./p[@class='abstract']")
      node_declaration = node.xpath("./pre[@class='declaration']")
      node_termdef     = node.xpath("./dl[@class='termdef']")

      node_termdef.size.times do |i|
        decl = node_declaration[i].text.strip
        if decl =~ /^(typedef\s+)?struct/
          parse_html_struct(node.child, code_struct)
          next
        end

        enum_name = (decl.match(/\}\s*([^\s]+);$/m).to_a)[1]
        is_enum = true if enum_name.to_s.length > 0

        if is_enum
          code_const << "# #{sanitize(node_abstract[i].text)}\n"
          code_const << "module #{enum_name} # Enumeration\n\n"
        end
        node_name        = node_termdef[i].xpath("./dt")
        node_description = node_termdef[i].xpath("./dd")
        node_name.size.times do |i|
          code_const << "  # #{sanitize(node_description[i].text.capitalize)}\n"
          code_const << "  #{node_name[i].text} = nil\n"
        end
        code_const << "end\n" if is_enum
      end
    end

    return code_const
  end

  def find_framework_path(doc)
    elem = doc.xpath(".//span[@class='FrameworkPath']")
    if elem.size > 0
      elem[0].parent.parent.parent.children[1].text
    else
      nil
    end
  end

  def parse_html_class_property_common(doc, code)
    code_const  = ''
    code_struct = ''
    parse_html_property(doc, code)
    parse_html_method(doc, code)
    parse_html_constant(doc, code_const, code_struct)

    code << "end\n"
    code << code_const
    code << code_struct
    return code
  end

  def parse_html_class(name, doc, code)
    # Find superclass (mandatory).
    sclass = nil
    doc.xpath("//table[@class='specbox']/tr").each do |node|
      if md = node.text.match(/Inherits from([^ ]+)/)
        sclass = md[1]
        break
      end
    end
    return nil unless sclass

    # Class abstract.
    code << doc.xpath(".//p[@class='abstract']")[0].text.gsub(/^/m, '# ')
    if sclass == "none"
      code << "\nclass #{name}\n\n"
    else
      code << "\nclass #{name} < #{sclass}\n\n"
    end

    parse_html_class_property_common(doc, code)
    return code
  end

  def parse_html_protocol(name, doc, code)
    # Class abstract.
    node = doc.xpath(".//p[@class='abstract']")
    return nil if node.empty?

    # FIXME : To avoid overwriting NSObject class reference by NSObject protocol reference
    return nil if name == "NSObject"

    code << node.text.gsub(/^/m, '# ')
    code << "\nmodule #{name} # Protocol\n\n"

    parse_html_class_property_common(doc, code)
    return code
  end

  def parse_html_function(doc, code = "")
    node_name        = doc.xpath("../h3[@class='tight jump function']")
    node_abstract    = doc.xpath("../p[@class='abstract']")
    node_declaration = doc.xpath("../pre[@class='declaration']")
    node_termdef     = doc.xpath("../div[@class='api parameters']/dl[@class='termdef']")
    node_return_val  = doc.xpath("../div[@class='return_value']/p")

    node_name.size.times do |i|
      name        = node_name[i].text
      abstract    = node_abstract[i].text
      declaration = node_declaration[i].text.strip


      declaration =~ /([^\s]+)\s+.+/
      return_type = $1

      declaration =~ /\((.+)\);/mx
      args = $1
      next unless args
      args = args.split(",")
      next unless args.size > 0

      return_type.strip!
      code << "# #{sanitize(abstract)}\n"

      node_param_description = node_termdef.xpath("dd")
      params = []
      args.each_with_index do |arg, index|
        arg.strip!
        arg =~ /(.+)\s+([^\s]+),?$/
        type  = $1
        param = $2
        next unless param

        param.sub!(/\*+/, '')
        type << Regexp.last_match.to_s
        params << param

        description = node_param_description[index].text if node_param_description[index]
        code << "# @param [#{parse_type(type)}] #{param} #{sanitize(description)}\n"
      end

      if node_return_val[i]
        code << "# @return [#{parse_type(return_type)}] #{sanitize(node_return_val[i].text)}\n"
      elsif return_type != "void"
        code << "# @return [#{parse_type(return_type)}]\n"
      else
        code << "# @return [nil]\n"
      end
      code << "def #{name}("
      if params.size > 0
        params.each do |param|
          code << "#{param}, "
        end
        code.slice!(-2, 2) # remove last ", "
      end
      code << "); end\n\n"

    end

    return code
  end

  def parse_html_struct(doc, code = "")
    node_name        = doc.xpath("../h3[@class='tight jump struct']|../h3[@class='tight jump typeDef']")
    node_abstract    = doc.xpath("../p[@class='abstract']")
    node_declaration = doc.xpath("../pre[@class='declaration']|../table[@class='zDeclaration']")
    node_termdef     = doc.xpath("../dl[@class='termdef']")
    current_member_position = 0

    node_name.size.times do |i|
      name        = node_name[i].text
      abstract    = node_abstract[i].text
      declaration = node_declaration[i].text.strip
      if node_name[i].values[0].include?("typeDef") &&
         !(declaration =~ /^typedef struct/)
        next
      end

      members     = declaration.scan(/\{([^\}]+)\}/)
      members     = members[0][0].strip.split(/;/) if members.size > 0
      unless members.empty?
        code << "# #{sanitize(abstract)}\n"
        code << "class #{name} < Boxed\n"

        members = members.inject([]) { |ary, item|
          # split 'double x, y, z, w;' to each line
          item.strip =~ /([^\s]+)\s+(.+)/
          type   = $1
          member = $2
          if type && member
            member.split(",").each do |m|
              ary << "#{type} #{m}"
            end
          end
          ary
        }

        node_field_description = node_termdef.xpath("dd")
        members.each do |item|
          item.strip =~ /(.+)\s+(.+)/
          type   = $1
          member = $2
          desc   = node_field_description[current_member_position]
          code << "  # @return [#{parse_type(type)}] #{desc ? sanitize(desc.text) : ''}\n"
          code << "  attr_accessor :#{member}\n"
          current_member_position += 1
        end
        code << "end\n\n"
      end
    end

    node_name.remove
    return code
  end

  def parse_html_reference(name, doc, code)
    if node = doc.xpath("//section/a[@title='Functions']")
      parse_html_function(node, code)
    end
    if node = doc.xpath("//section/a[@title='Data Types']")
      parse_html_struct(node, code)
    end

    return code
  end

  def parse_html_data(data)
    doc = Nokogiri::HTML(data)
    title = doc.xpath('/html/head/title')
    if title
      code = ''
      if framework_path = find_framework_path(doc)
        code << "# -*- framework: #{framework_path} -*-\n\n"
      else
        #$stderr.puts "Can't determine framework path for: #{name}"
        code << "\n\n"
      end

      if md = title.text.match(/^(.+)Class Reference$/)
        parse_html_class(md[1].strip, doc, code)
      elsif md = title.text.match(/^(.+)Protocol Reference$/)
        parse_html_protocol(md[1].strip, doc, code)
      elsif md = title.text.match(/^(.+) Reference$/)
        parse_html_reference(md[1].strip, doc, code)
      end
    else
      nil
    end
  end

  def self.modify_document_title(path, new_title)
    unless File.exists?(path)
      warn "File not exists : #{path}"
      return nil
    end
    data = File.read(path)
    data.gsub!(/\s*Module:/, new_title + ':')

    File.open(path, "w") { |io| io.print data }
  end

  def initialize(outpath, paths)
    @input_paths = []
    paths.each do |path|
      path = File.expand_path(path)
      if File.directory?(path)
        @input_paths.concat(Dir.glob(path + '/**/*.html'))
      else
        @input_paths << path
      end
    end
    @outpath = outpath
    @rb_files_dir = '/tmp/rb_docset'
  end

  def generate_ruby_code
    FileUtils.rm_rf(@rb_files_dir)
    FileUtils.mkdir_p(@rb_files_dir)

    @input_paths.map { |path| parse_html_data(File.read(path)) }.compact.each_with_index do |code, n|
      File.open(File.join(@rb_files_dir, "t#{n}.rb"), 'w') do |io|
        io.puts "# -*- coding: utf-8 -*-"
        io.write(code)
      end
    end
  end

  def generate_html
    sh "yard doc #{@rb_files_dir}"
    sh "mv doc \"#{@outpath}\""
  end

  def run
    generate_ruby_code()
    generate_html()
  end
end
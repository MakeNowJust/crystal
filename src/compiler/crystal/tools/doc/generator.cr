class Crystal::Doc::Generator
  getter program : Program

  @base_dir : String
  getter project_info

  # Adding a flag and associated css class will add support in parser
  FLAG_COLORS = {
    "BUG"          => "red",
    "DEPRECATED"   => "red",
    "EXPERIMENTAL" => "lime",
    "FIXME"        => "yellow",
    "NOTE"         => "purple",
    "OPTIMIZE"     => "green",
    "TODO"         => "orange",
  }
  FLAGS = FLAG_COLORS.keys

  def self.new(program : Program, included_dirs : Array(String))
    new(program, included_dirs, ".", "html", nil, "1.0", "never", ProjectInfo.new("test", "0.0.0-test"))
  end

  def initialize(@program : Program, @included_dirs : Array(String),
                 @output_dir : String, @output_format : String,
                 @sitemap_base_url : String?,
                 @sitemap_priority : String, @sitemap_changefreq : String,
                 @project_info : ProjectInfo)
    @base_dir = Dir.current.chomp
    @types = {} of Crystal::Type => Doc::Type
  end

  def run
    types = collect_subtypes(@program)

    program_type = type(@program)
    if must_include_toplevel? program_type
      types.insert 0, program_type
    end

    if @output_format == "json"
      generate_docs_json program_type, types
    else
      generate_docs_html program_type, types
    end
  end

  def program_type
    type(@program)
  end

  def read_readme
    if File.file?("README.md")
      filename = "README.md"
    elsif File.file?("Readme.md")
      filename = "Readme.md"
    end

    if filename
      content = File.read(filename)
    else
      content = ""
    end

    content
  end

  def generate_docs_json(program_type, types)
    readme = read_readme
    json = Main.new(readme, Type.new(self, @program), project_info)
    puts json
  end

  def generate_docs_html(program_type, types)
    copy_files
    generate_types_docs types, @output_dir, types
    generate_readme program_type, types
    generate_sitemap types
  end

  def generate_readme(program_type, types)
    raw_body = read_readme
    body = doc(program_type, raw_body)

    File.write File.join(@output_dir, "index.html"), MainTemplate.new(body, types, project_info)

    main_index = Main.new(raw_body, Type.new(self, @program), project_info)
    File.write File.join(@output_dir, "index.json"), main_index
    File.write File.join(@output_dir, "search-index.js"), main_index.to_jsonp
  end

  def generate_sitemap(types)
    if sitemap_base_url = @sitemap_base_url
      File.write File.join(@output_dir, "sitemap.xml"), SitemapTemplate.new(types, sitemap_base_url, "1.0", "never")
    end
  end

  def copy_files
    Dir.mkdir_p File.join(@output_dir, "css")
    Dir.mkdir_p File.join(@output_dir, "js")

    File.write File.join(@output_dir, "css", "style.css"), StyleTemplate.new
    File.write File.join(@output_dir, "js", "doc.js"), JsTypeTemplate.new
  end

  def generate_types_docs(types, dir, all_types)
    types.each do |type|
      if type.program?
        filename = File.join(dir, "toplevel.html")
      else
        filename = File.join(dir, "#{type.name}.html")
      end

      File.write filename, TypeTemplate.new(type, all_types, project_info)

      next if type.program?

      subtypes = type.types
      if subtypes && !subtypes.empty?
        dirname = File.join(dir, type.name)
        Dir.mkdir_p dirname
        generate_types_docs subtypes, dirname, all_types
      end
    end
  end

  def must_include?(type : Doc::Type)
    must_include? type.type
  end

  def must_include?(type : Crystal::Type)
    return false if type.private?
    return false if nodoc?(type, type.locations.try(&.first?))
    return true if crystal_builtin?(type)

    # Don't include lib types or types inside a lib type
    return false if type.is_a?(Crystal::LibType) || type.namespace.is_a?(LibType)

    type.locations.try &.any? do |type_location|
      must_include? type_location
    end
  end

  def must_include?(method : Method)
    must_include? method.def
  end

  def must_include?(a_def : Crystal::Def)
    return false if nodoc?(a_def, a_def.location)

    must_include? a_def.location
  end

  def must_include?(a_macro : Doc::Macro)
    must_include? a_macro.macro
  end

  def must_include?(a_macro : Crystal::Macro)
    return false if nodoc?(a_macro, a_macro.location)

    must_include? a_macro.location
  end

  def must_include?(constant : Constant)
    must_include? constant.const
  end

  def must_include?(const : Crystal::Const)
    return false if nodoc?(const, const.locations.try(&.first?))
    return true if crystal_builtin?(const)

    const.locations.try &.any? { |location| must_include? location }
  end

  def must_include?(location : Crystal::Location)
    case filename = location.filename
    when String
      @included_dirs.any? { |included_dir| filename.starts_with? included_dir }
    when VirtualFile
      must_include? filename.expanded_location
    else
      false
    end
  end

  def must_include?(a_nil : Nil)
    false
  end

  def must_include_toplevel?(program_type : Type)
    toplevel_items = [] of Method | Macro | Constant
    toplevel_items.concat program_type.class_methods
    toplevel_items.concat program_type.macros
    toplevel_items.concat program_type.constants

    toplevel_items.any? { |item| must_include? item }
  end

  # TODO: remove after 0.34.0
  # Needed because there are multiple passes while generating docs
  # and we want to avoid duplicate warnings per location
  @nodoc_warnings_locations = Set(String).new

  def nodoc?(str : String?, location : Location?) : Bool
    return false if !str || !@program.wants_doc?

    # TODO: remove after 0.34.0
    if str.starts_with?("nodoc")
      if location
        # Show one line above to highlight the nodoc line
        location = Location.new(location.filename, location.line_number - 1, location.column_number)
      end

      if !location || @nodoc_warnings_locations.add?(location.to_s)
        @program.report_warning_at location, "`nodoc` is no longer supported. Use `:nodoc:` instead"
      end
      return true
    end

    str.starts_with?(":nodoc:")
  end

  def nodoc?(obj, location : Location?)
    nodoc? obj.doc.try(&.strip), location
  end

  def crystal_builtin?(type)
    return false unless project_info.crystal_stdlib?
    return false unless type.is_a?(Const) || type.is_a?(NonGenericModuleType)

    crystal_type = @program.types["Crystal"]
    return true if type == crystal_type

    return false unless type.is_a?(Const)
    return false unless type.namespace == crystal_type

    {"BUILD_COMMIT", "BUILD_DATE", "CACHE_DIR", "DEFAULT_PATH",
     "DESCRIPTION", "PATH", "VERSION", "LLVM_VERSION",
     "LIBRARY_PATH"}.each do |name|
      return true if type == crystal_type.types[name]?
    end

    false
  end

  def type(type)
    @types[type] ||= Type.new(self, type)
  end

  def method(type, method, class_method)
    Method.new(self, type, method, class_method)
  end

  def macro(type, a_macro)
    Macro.new(self, type, a_macro)
  end

  def collect_subtypes(parent)
    types = [] of Type

    # AliasType has defined `types?` to be the types
    # of the aliased type, but for docs we don't want
    # to list the nested types for aliases.
    if parent.is_a?(AliasType)
      return types
    end

    parent.types?.try &.each_value do |type|
      case type
      when Const, LibType
        next
      else
        types << type(type) if must_include? type
      end
    end

    types.sort_by! &.name.downcase
  end

  def collect_constants(parent)
    types = [] of Constant

    parent.type.types?.try &.each_value do |type|
      if type.is_a?(Const) && must_include?(type) && !type.private?
        types << Constant.new(self, parent, type)
      end
    end

    types.sort_by! &.name.downcase unless parent.type.is_a?(EnumType)
    types
  end

  def summary(obj : Type | Method | Macro | Constant)
    doc = obj.doc

    return if !doc && !has_doc_annotations?(obj)

    summary obj, doc || ""
  end

  def summary(context, string)
    line = fetch_doc_lines(string).lines.first? || ""

    dot_index = line =~ /\.($|\s)/
    if dot_index
      line = line[0..dot_index]
    end

    doc context, line
  end

  def doc(obj : Type | Method | Macro | Constant)
    doc = obj.doc

    return if !doc && !has_doc_annotations?(obj)

    doc obj, doc || ""
  end

  def has_doc_annotations?(obj)
    obj.annotations(@program.deprecated_annotation) || obj.annotations(@program.experimental_annotation)
  end

  def doc(context, string)
    string = isolate_flag_lines string
    string += build_flag_lines_from_annotations context
    markdown = String.build do |io|
      Markdown.parse string, Markdown::DocRenderer.new(context, io)
    end
    generate_flags markdown
  end

  def fetch_doc_lines(doc : String) : String
    doc.gsub /\n+/ { |match| match.size == 1 ? " " : "\n" }
  end

  # Replaces flag keywords with html equivalent
  #
  # Assumes that flag keywords are at the beginning of respective `p` element
  def generate_flags(string)
    FLAGS.reduce(string) do |str, flag|
      flag_regexp = /<p>\s*#{flag}:?/
      element_sub = %(<p><span class="flag #{FLAG_COLORS[flag]}">#{flag}</span> )
      str.gsub(flag_regexp, element_sub)
    end
  end

  # Adds extra line break to flag keyword lines
  #
  # Guarantees that line is within its own paragraph element when parsed
  def isolate_flag_lines(string)
    flag_regexp = /^ ?(#{FLAGS.join('|')}):?/
    String.build do |io|
      string.each_line(chomp: false).join(io) do |line, io|
        if line =~ flag_regexp
          io << '\n' << line
        else
          io << line
        end
      end
    end
  end

  def build_flag_lines_from_annotations(context)
    first = true
    String.build do |io|
      if anns = context.annotations(@program.deprecated_annotation)
        anns.each do |ann|
          io << "\n\n" if first
          first = false
          io << "DEPRECATED: #{DeprecatedAnnotation.from(ann).message}\n\n"
        end
      end

      if anns = context.annotations(@program.experimental_annotation)
        anns.each do |ann|
          io << "\n\n" if first
          first = false
          io << "EXPERIMENTAL: #{ExperimentalAnnotation.from(ann).message}\n\n"
        end
      end
    end
  end

  def source_link(node)
    location = RelativeLocation.from(node, @base_dir)
    return unless location
    project_info.source_url(location)
  end

  SRC_SEP = "src#{File::SEPARATOR}"

  def relative_locations(type)
    locations = [] of RelativeLocation
    type.locations.try &.each do |location|
      location = RelativeLocation.from(location, @base_dir)
      next unless location
      filename = location.filename
      next unless filename

      url = project_info.source_url(location)
      next unless url
      location.url = url

      # Prevent identical link generation in the "Defined in:" section in the docs because of macros
      next if locations.includes?(location)

      same_file_location = locations.find { |loc| loc.filename == filename }
      if same_file_location
        location.show_line_number = true
        same_file_location.show_line_number = true
      end

      locations << location
    end
    locations.sort
  end

  def highlight(code)
    begin
      Highlighter.highlight(code)
    rescue
      # TODO: show warning message on error
      code
    end
  end
end

class Savi::Compiler::SourceService
  property standard_library_dirname =
    File.expand_path("../../../packages", __DIR__)
  property standard_directory_remap : {String, String}?
  property main_directory_remap : {String, String}?

  def initialize
    @source_overrides = {} of String => Hash(String, String)
  end

  # Add/update a source override, which causes the SourceService to pretend as
  # if there is a file at the given path with the given content in it.
  #
  # If there really is a file at that path, the source override will shadow it,
  # overriding the real content of the file for as long as the override exists.
  # If there is no such file at that path, the source override makes the system
  # pretend as if there is a file there, so it will show up in that directory
  # if and when the directory is compiled as a library in the program.
  #
  # This is used by editor-interactive systems like the language server,
  # allowing the content in the text editor that has opened the given file
  # to temporarily override whatever content is actually saved to disk there.
  # This allows us to compile as the user is typing, even if they haven't saved.
  def set_source_override(path, content)
    dirname = File.dirname(path)
    name = File.basename(path)
    (@source_overrides[dirname] ||= {} of String => String)[name] = content
  end

  # Remove the source override at the given path, if it exists.
  #
  # This corresponds to the closing of a file in a text editor.
  #
  # See docs for `set_source_override` for more information.
  def unset_source_override(path)
    dirname = File.dirname(path)
    name = File.basename(path)
    @source_overrides[dirname]?.try(&.delete(name))
    @source_overrides.delete(dirname)
  end

  # Get the source object at the given path, either an override or real file.
  def get_source_at(path)
    dirname = File.dirname(path)
    name = File.basename(path)
    content = @source_overrides[dirname]?.try(&.[]?(name)) || File.read(path)
    library = Source::Library.new(dirname)

    Source.new(dirname, name, content, library)
  end

  # Check if the given directory exists, either in reality or in an override.
  private def dir_exists?(dirname)
    Dir.exists?(dirname) || @source_overrides.has_key?(dirname)
  end

  # Yield the name and content of each Savi file in this dirname.
  private def each_savi_file_in(dirname)
    dir_source_overrides = @source_overrides[dirname]?

    # Yield the real files and their content.
    Dir.entries(dirname).each { |name|
      next unless name.ends_with?(".savi")

      # If this is a filename that has overridden content, omit it for now.
      # We will yield it later when yielding all the other overrides.
      next if dir_source_overrides.try(&.has_key?(name))

      # Try to read the content from the file, or skip it if we fail for any
      # reason, such as filesystem issues or deletion race conditions.
      content = File.read(File.join(dirname, name)) rescue nil
      next unless content

      yield ({name, content})
    }

    # Now yield the fake files implied by the source overrides for this dirname.
    dir_source_overrides.try(&.each { |name, content| yield ({name, content}) })
  end

  # Yield the dirname, name, content of each Savi file in each subdirectory.
  private def each_savi_file_in_recursive(root_dirname)
    # Yield the real files and their content.
    Dir.glob("#{root_dirname}/**/*.savi").each { |path|
      name = File.basename(path)
      dirname = File.dirname(path)

      # If this is a filename that has overridden content, omit it for now.
      # We will yield it later when yielding all the other overrides.
      next if @source_overrides[dirname]?.try(&.[]?(name))

      # Try to read the content from the file, or skip it if we fail for any
      # reason, such as filesystem issues or deletion race conditions.
      content = File.read(path) rescue nil
      next unless content

      yield ({dirname, name, content})
    }

    # Now yield the fake files implied by the source overrides for this dirname.
    @source_overrides.each { |dirname, dir_source_overrides|
      next unless dirname.starts_with?(root_dirname)

      dir_source_overrides.each { |name, content|
        yield ({dirname, name, content})
      }
    }
  end

  # Given a library name, optionally anchored to a given "from directory" name,
  # try to resolve a directory that matches the library name.
  #
  # First a relative location will be attempted if a "from directory" was given.
  # Then a standard library location will be attempted.
  # If both attempts fail, there is no hope of resolving the library.
  def resolve_library_dirname(libname, from_dirname = nil)
    standard_dirname = File.expand_path(libname, standard_library_dirname)
    relative_dirname = File.expand_path(libname, from_dirname) if from_dirname

    if relative_dirname && dir_exists?(relative_dirname)
      relative_dirname
    elsif dir_exists?(standard_dirname)
      standard_dirname
    else
      raise "Couldn't find a library directory named #{libname.inspect}" \
        "#{" (relative to #{from_dirname.inspect})" if from_dirname}"
    end
  end

  # Given a directory name, load source objects for all the source files in it.
  def get_library_sources(dirname, library : Source::Library? = nil)
    library ||= Source::Library.new(dirname)

    sources = [] of Source
    each_savi_file_in(dirname) { |name, content|
      sources << Source.new(dirname, name, content, library)
    }

    Error.at Source::Pos.show_library_path(library),
      "No '.savi' source files found in this directory" \
        if sources.empty?

    # Sort the sources by case-insensitive name, so that they always get loaded
    # in a repeatable order regardless of platform implementation details, or
    # the possible presence of source overrides shadowing some of the files.
    sources.sort_by!(&.filename.downcase)

    sources
  end

  # Given a directory name, load source objects for all the source files in
  # each subdirectory of that root directory, grouped by source library.
  def get_recursive_sources(root_dirname, language = :savi)
    sources = {} of Source::Library => Array(Source)
    each_savi_file_in_recursive(root_dirname) { |dirname, name, content|
      library = Source::Library.new(dirname)

      (sources[library] ||= [] of Source) \
        << Source.new(dirname, name, content, library)
    }

    Error.at Source::Pos.show_library_path(Source::Library.new(root_dirname)),
      "No '.savi' source files found recursively within this root" \
        if sources.empty?

    # Sort the sources by case-insensitive name, so that they always get loaded
    # in a repeatable order regardless of platform implementation details, or
    # the possible presence of source overrides shadowing some of the files.
    sources.each(&.last.sort_by!(&.filename.downcase))
    sources.to_a.sort_by!(&.first.path.downcase)
  end
end

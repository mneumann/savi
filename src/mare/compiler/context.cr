class Mare::Compiler::Context
  getter program
  getter namespace
  getter refer_type
  getter inventory
  getter infer
  getter refer
  getter reach
  getter paint
  getter code_gen
  getter lifetime
  getter code_gen_verona
  getter eval
  getter serve_hover

  def initialize
    @program = Program.new
    @stack = [] of Interpreter

    @namespace = Namespace.new
    @refer_type = ReferType.new
    @inventory = Inventory.new
    @infer = Infer.new
    @refer = Refer.new
    @reach = Reach.new
    @paint = Paint.new
    @code_gen = CodeGen.new(CodeGen::PonyRT)
    @lifetime = Lifetime.new
    @code_gen_verona = CodeGen.new(CodeGen::VeronaRT)
    @eval = Eval.new
    @serve_hover = ServeHover.new
  end

  def compile_library(source_library : Source::Library, docs : Array(AST::Document))
    library = Program::Library.new
    library.source_library = source_library

    docs.each do |doc|
      @stack.unshift(Interpreter::Default.new(library))
      doc.list.each { |decl| compile_decl(decl) }
      @stack.reverse_each &.finished(self)
      @stack.shift
    end

    @program.libraries << library
    library
  end

  def compile_decl(decl : AST::Declare)
    loop do
      raise "Unrecognized keyword: #{decl.keyword}" if @stack.size == 0
      break if @stack.last.keywords.includes?(decl.keyword)
      @stack.pop.finished(self)
    end

    @stack.last.compile(self, decl)
  end

  def finish
    @stack.clear
  end

  def push(compiler)
    @stack.push(compiler)
  end

  def run(obj)
    @program.libraries.each do |library|
      obj.run(self, library)
    end
    finish
    obj
  end

  def run_copy_on_mutate(obj)
    @program.libraries.map! do |library|
      obj.run(self, library)
    end
    finish
    obj
  end

  def run_whole_program(obj)
    obj.run(self)
    finish
    obj
  end
end

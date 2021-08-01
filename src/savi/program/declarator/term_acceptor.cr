abstract class Savi::Program::Declarator::TermAcceptor
  abstract def name : String
  abstract def try_accept(term : AST::Term) : AST::Term?

  abstract def describe : String
  def describe_post : String
    ""
  end

  property! pos : Source::Pos
  property optional : Bool = false
  property default : AST::Term?
  def try_default : AST::Term?
    @default
  end

  class Keyword < TermAcceptor
    getter keyword : String

    def initialize(@pos, @keyword)
    end

    def name : String
      "_" # we don't care about where we save the term
    end

    def try_accept(term : AST::Term) : AST::Term?
      term if term.is_a?(AST::Identifier) && term.value == @keyword
    end

    def describe : String
      "the keyword `#{keyword}`"
    end
  end

  class Enum < TermAcceptor
    getter name : String
    getter possible : Array(String)

    def initialize(@pos, @name, @possible)
    end

    def try_accept(term : AST::Term) : AST::Term?
      return unless term.is_a?(AST::Identifier)

      term if @possible.includes?(term.value)
    end

    def describe : String
      "any of these"
    end
    def describe_post : String
      ": `#{@possible.join("`, `")}`"
    end
  end

  class Typed < TermAcceptor
    getter name : String
    getter type : String

    def initialize(@pos, @name, @type)
    end

    def self.try_accept(term : AST::Term, type : String) : AST::Term?
      case type
      when "Term"
        term
      when "String"
        term if term.is_a?(AST::LiteralString)
      when "Name"
        case term
        when AST::Identifier
          term
        when AST::LiteralString
          AST::Identifier.new(term.value).from(term)
        end
      when "Type"
        term if (
          case term
          when AST::Identifier
            true
          when AST::Qualify
            try_accept(term.term, type) &&
            term.group.terms.all? { |term2| try_accept(term2, type) }
          when AST::Relate
            ["'", "->"].includes?(term.op.value) &&
            try_accept(term.lhs, type) &&
            try_accept(term.rhs, type)
          when AST::Group
            (
              (term.style == "(" && term.terms.size == 1) ||
              (term.style == "|")
            ) &&
            term.terms.all? { |term2| try_accept(term2, type) }
          else false
          end
        )
      when "NameList"
        if term.is_a?(AST::Group) && term.style == "("
          group = AST::Group.new("(").from(term)
          list = term.terms.each { |term2|
            term2 = try_accept(term2, "Name")
            return unless term2
            group.terms << term2
          }
          group
        end
      when "TypeOrTypeList"
        try_accept(term, "Type") || begin
          if term.is_a?(AST::Group) && term.style == "("
            group = AST::Group.new("(").from(term)
            list = term.terms.each { |term2|
              term2 = try_accept(term2, "Type")
              return unless term2
              group.terms << term2
            }
            group
          end
        end
      when "Params"
        if term.is_a?(AST::Group) && term.style == "("
          # TODO: more specific requirements here
          term
        end
      when "NameMaybeWithParams"
        try_accept(term, "Name") || begin
          if term.is_a?(AST::Qualify)
            AST::Qualify.new(
              try_accept(term.term, "Name") || return,
              try_accept(term.group, "Params") || return,
            ).from(term)
          end
        end
      else
        raise NotImplementedError.new(type)
      end
    end

    def try_accept(term : AST::Term) : AST::Term?
      self.class.try_accept(term, @type)
    end

    def describe : String
      case type
      when "Term"
        "any term"
      when "String"
        "a string literal"
      when "Name"
        "an identifier or string literal"
      when "Type"
        "an algebraic type expression"
      when "NameList"
        "a parenthesized group of identifiers or string literals"
      when "TypeOrTypeList"
        "an algebraic type or parenthesized group of algebraic types"
      when "Params"
        "a parenthesized list of parameter specifiers"
      when "NameMaybeWithParams"
        "a name with an optional parenthesized list of parameter specifiers"
      else
        raise NotImplementedError.new(type)
      end
    end
  end
end
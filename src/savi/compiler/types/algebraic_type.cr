module Savi::Compiler::Types
  abstract struct AlgebraicType
    def inspect; show; end
    abstract def show

    abstract def intersect(other : AlgebraicType)

    def aliased
      raise NotImplementedError.new("aliased for #{self.class}")
    end

    def stabilized
      raise NotImplementedError.new("stabilized for #{self.class}")
    end

    def override_cap(cap : AlgebraicType)
      raise NotImplementedError.new("override_cap for #{self.class}")
    end

    def viewed_from(origin)
      raise NotImplementedError.new("viewed_from for #{self.class}")
    end
  end

  abstract struct AlgebraicTypeSummand < AlgebraicType
    def unite(other : AlgebraicType)
      case other
      when AlgebraicTypeSummand
        Union.new(Set(AlgebraicTypeSummand){self, other})
      else
        other.unite(self)
      end
    end
  end

  abstract struct AlgebraicTypeFactor < AlgebraicTypeSummand
    def intersect(other : AlgebraicType)
      case other
      when AlgebraicTypeFactor
        Intersection.new(Set(AlgebraicTypeFactor){self, other})
      else
        other.intersect(self)
      end
    end

    def viewed_from(origin)
      Viewpoint.new(origin, self)
    end
  end

  abstract struct AlgebraicTypeSimple < AlgebraicTypeFactor
    def aliased
      Aliased.new(self)
    end

    def stabilized
      Stabilized.new(self)
    end
  end

  struct JumpsAway < AlgebraicType
    getter pos : Source::Pos
    def initialize(@pos)
    end

    def show
      "(jumps away)"
    end

    def intersect(other : AlgebraicType)
      # No matter what you intersect, the type is still just not there.
      # It has jumped away without leaving anything to intersect with.
      self
    end

    def unite(other : AlgebraicType)
      # Whatever the other type is, we use it and abandon this lack of a type.
      other
    end

    def aliased
      self # doesn't change the nature of this lack of a type
    end

    def stabilized
      self # doesn't change the nature of this lack of a type
    end

    def override_cap(cap : AlgebraicType)
      self # doesn't change the nature of this lack of a type
    end
  end

  struct NominalType < AlgebraicTypeSimple
    getter link : Program::Type::Link
    getter args : Array(AlgebraicType)?
    def initialize(@link, @args = nil)
    end

    def show
      args = @args
      args ? "#{@link.name}(#{args.map(&.show).join(", ")})" : @link.name
    end

    def aliased
      self # this type says nothing about capabilities, so it remains unchanged.
    end

    def stabilized
      self # this type says nothing about capabilities, so it remains unchanged.
    end

    def override_cap(cap : AlgebraicType)
      intersect(cap)
    end

    def viewed_from(origin)
      self # this type says nothing about capabilities, so it remains unchanged.
    end
  end

  struct NominalCap < AlgebraicTypeSimple
    enum Value : UInt8
      ISO
      ISO_ALIASED
      REF
      VAL
      BOX
      TAG
      NON
    end
    getter cap : Value # TODO: probably an enum
    def initialize(@cap)
    end

    ISO         = new(Value::ISO)
    ISO_ALIASED = new(Value::ISO_ALIASED)
    REF         = new(Value::REF)
    VAL         = new(Value::VAL)
    BOX         = new(Value::BOX)
    TAG         = new(Value::TAG)
    NON         = new(Value::NON)

    ANY   = Union.new(Set(AlgebraicTypeSummand){ISO, REF, VAL, BOX, TAG, NON})
    ALIAS = Union.new(Set(AlgebraicTypeSummand){REF, VAL, BOX, TAG, NON})
    SEND  = Union.new(Set(AlgebraicTypeSummand){ISO, VAL, TAG, NON})
    SHARE = Union.new(Set(AlgebraicTypeSummand){VAL, TAG, NON})
    READ  = Union.new(Set(AlgebraicTypeSummand){REF, VAL, BOX})

    def show
      @cap.to_s.downcase
    end

    def aliased
      case self
      when ISO then ISO_ALIASED
      when ISO_ALIASED then raise "unreachable: we should never alias an alias"
      else self # all other caps alias as themselves
      end
    end

    def stabilized
      case self
      when ISO_ALIASED then TAG # TODO: NON instead, for Verona compatibility
      else self # all other caps stabilize as themselves
      end
    end

    def override_cap(other : AlgebraicType)
      other
    end
  end

  struct TypeVariable < AlgebraicTypeSimple
    getter nickname : String
    getter scope : Program::Function::Link | Program::Type::Link | Program::TypeAlias::Link
    getter sequence_number : UInt64
    def initialize(@nickname, @scope, @sequence_number)
    end

    def show
      scope_sym = scope.is_a?(Program::Function::Link) ? "'" : "'^"
      "T'#{@nickname}#{scope_sym}#{@sequence_number}"
    end

    def override_cap(other : AlgebraicType)
      OverrideCap.new(self, other)
    end
  end

  struct CapVariable < AlgebraicTypeSimple
    getter nickname : String
    getter scope : Program::Function::Link | Program::Type::Link | Program::TypeAlias::Link
    getter sequence_number : UInt64
    def initialize(@nickname, @scope, @sequence_number)
    end

    def show
      scope_sym = scope.is_a?(Program::Function::Link) ? "'" : "'^"
      "K'#{@nickname}#{scope_sym}#{@sequence_number}"
    end

    def override_cap(cap : AlgebraicType)
      cap # overrides whatever cap was sitting behind this variable
    end
  end

  struct Viewpoint < AlgebraicTypeSimple
    getter origin : StructRef(AlgebraicTypeSimple)
    getter target : StructRef(AlgebraicTypeFactor)
    def initialize(origin, target)
      if origin.is_a?(Intersection)
        origin = Intersection.from(
          origin.members.reject(&.is_a?(NominalType))
        )
      end

      @origin = StructRef(AlgebraicTypeSimple).new(origin.as(AlgebraicTypeSimple))
      @target = StructRef(AlgebraicTypeFactor).new(target)
    end

    def show
      "#{@origin.show}->#{@target.show}"
    end
  end

  struct OverrideCap < AlgebraicTypeFactor
    getter inner : AlgebraicTypeSimple
    getter cap : StructRef(AlgebraicType)
    def initialize(@inner, cap : AlgebraicType)
      @cap = StructRef(AlgebraicType).new(cap)
    end

    def show
      "#{@inner.show}'#{@cap.show}"
    end
  end

  struct Aliased < AlgebraicTypeFactor
    getter inner : AlgebraicTypeSimple
    def initialize(@inner)
    end

    def show
      "#{@inner.show}'aliased"
    end

    def aliased
      raise "unreachable: we should never alias an alias"
    end

    def stabilized
      # If we stabilize an alias, only those caps with no uniqueness constraints
      # can remain in play - if an iso'aliased is present, it drops away.
      NoUnique.new(inner)
    end
  end

  struct Stabilized < AlgebraicTypeFactor
    getter inner : AlgebraicTypeSimple
    def initialize(@inner)
    end

    def show
      "#{@inner.show}'stabilized"
    end
  end

  struct NoUnique < AlgebraicTypeFactor
    getter inner : AlgebraicTypeSimple
    def initialize(@inner)
    end

    def show
      "#{@inner.show}'nounique"
    end
  end

  struct Intersection < AlgebraicTypeSummand
    getter members : Set(AlgebraicTypeFactor)
    def initialize(@members)
    end

    def self.from(list)
      result : AlgebraicType? = nil
      list.each { |member|
        result = result ? result.intersect(member) : member
      }
      result.not_nil!
    end

    def show
      "(#{@members.map(&.show).join(" & ")})"
    end

    def intersect(other : AlgebraicType)
      case other
      when AlgebraicTypeFactor
        Intersection.new(@members.dup.tap(&.add(other)))
      when Intersection
        Intersection.new(@members + other.members)
      else
        other.intersect(self)
      end
    end

    def aliased
      Intersection.from(@members.map(&.aliased))
    end

    def stabilized
      Intersection.from(@members.map(&.stabilized))
    end

    def override_cap(cap : AlgebraicType)
      Intersection.from(@members.map(&.override_cap(cap)))
    end

    def viewed_from(origin)
      Intersection.from(@members.map(&.viewed_from(origin)))
    end
  end

  struct Union < AlgebraicType
    getter members : Set(AlgebraicTypeSummand)
    def initialize(@members)
    end

    def self.from(list)
      result : AlgebraicType? = nil
      list.each { |member|
        result = result ? result.unite(member) : member
      }
      result.not_nil!
    end

    def show
      "(#{@members.map(&.show).join(" | ")})"
    end

    def intersect(other : AlgebraicType)
      Union.from(@members.map(&.intersect(other)))
    end

    def unite(other : AlgebraicType)
      case other
      when AlgebraicTypeSummand
        Union.new(@members.dup.tap(&.add(other)))
      when Union
        Union.new(@members + other.members)
      else
        other.unite(self)
      end
    end

    def aliased
      Union.from(@members.map(&.aliased))
    end

    def stabilized
      Union.from(@members.map(&.stabilized))
    end

    def override_cap(cap : AlgebraicType)
      Union.from(@members.map(&.override_cap(cap)))
    end

    def viewed_from(origin)
      Union.from(@members.map(&.viewed_from(origin)))
    end
  end
end
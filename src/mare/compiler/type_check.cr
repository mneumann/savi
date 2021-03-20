require "levenshtein"

##
# TODO: Document this pass
#
class Mare::Compiler::TypeCheck
  alias MetaType = Infer::MetaType
  alias TypeParam = Infer::TypeParam
  alias ReifiedTypeAlias = Infer::ReifiedTypeAlias
  alias ReifiedType = Infer::ReifiedType
  alias ReifiedFunction = Infer::ReifiedFunction
  alias SubtypingInfo = Infer::SubtypingInfo
  alias Info = Infer::Info

  struct FuncAnalysis
    getter link

    # TODO: remove this alias
    protected def alt_infer; @spans; end

    def initialize(
      @link : Program::Function::Link,
      @pre : PreInfer::Analysis,
      @spans : AltInfer::FuncAnalysis
    )
      @reified_funcs = {} of ReifiedType => Set(ReifiedFunction)
    end

    def each_reified_func(rt : ReifiedType)
      @reified_funcs[rt]?.try(&.each) || ([] of ReifiedFunction).each
    end
    protected def observe_reified_func(rf)
      (@reified_funcs[rf.type] ||= Set(ReifiedFunction).new).add(rf)
    end

    def [](node : AST::Node); @pre[node]; end
    def []?(node : AST::Node); @pre[node]?; end
    def yield_in_info; @pre.yield_in_info; end
    def yield_out_infos; @pre.yield_out_infos; end
    def each_info(&block : Infer::Info -> Nil); @pre.each_info(&block); end

    def span(node : AST::Node); span(@spans[node]); end
    def span?(node : AST::Node); span?(@spans[node]?); end
    def span(info : Infer::Info); @spans[info]; end
    def span?(info : Infer::Info); @spans[info]?; end
  end

  struct TypeAnalysis
    protected getter partial_reifieds
    protected getter reached_fully_reifieds

    def initialize(@link : Program::Type::Link)
      @partial_reifieds = [] of ReifiedType
      @reached_fully_reifieds = [] of ReifiedType
    end

    def no_args
      ReifiedType.new(@link)
    end

    protected def observe_reified_type(ctx, rt)
      if rt.is_complete?(ctx)
        @reached_fully_reifieds << rt
      elsif rt.is_partial_reify?(ctx)
        @partial_reifieds << rt
      end
    end

    def each_partial_reified; @partial_reifieds.each; end
    def each_reached_fully_reified; @reached_fully_reifieds.each; end
    def each_non_argumented_reified
      if @partial_reifieds.empty?
        [no_args].each
      else
        @partial_reifieds.each
      end
    end
  end

  struct ReifiedTypeAnalysis
    protected getter subtyping

    def initialize(@rt : ReifiedType)
      @subtyping = SubtypingInfo.new(rt)
    end

    # TODO: Remove this and refactor callers to use the more efficient/direct variant?
    def is_subtype_of?(ctx : Context, other : ReifiedType, errors = [] of Error::Info)
      ctx.type_check[other].is_supertype_of?(ctx, @rt, errors)
    end

    def is_supertype_of?(ctx : Context, other : ReifiedType, errors = [] of Error::Info)
      @subtyping.check(ctx, other, errors)
    end

    def each_known_subtype
      @subtyping.each_known_subtype
    end

    def each_known_complete_subtype(ctx)
      each_known_subtype.flat_map do |rt|
        if rt.is_complete?(ctx)
          rt
        else
          ctx.type_check[rt.link].each_reached_fully_reified
        end
      end
    end
  end

  struct ReifiedFuncAnalysis
    protected getter resolved_infos
    protected getter called_funcs
    protected getter call_infers_for
    getter! ret_resolved : MetaType; protected setter ret_resolved
    getter! yield_in_resolved : MetaType; protected setter yield_in_resolved
    getter! yield_out_resolved : Array(MetaType?); protected setter yield_out_resolved

    def initialize(ctx : Context, @rf : ReifiedFunction)
      f = @rf.link.resolve(ctx)

      @is_constructor = f.has_tag?(:constructor).as(Bool)
      @resolved_infos = {} of Info => MetaType
      @called_funcs = Set({Source::Pos, ReifiedType, Program::Function::Link}).new

      # TODO: can this be removed or made more clean without sacrificing performance?
      @call_infers_for = {} of Infer::FromCall => Set({ForReifiedFunc, Bool})
    end

    def reified
      @rf
    end

    # TODO: rename as [] and rename [] to info_for or similar?
    def resolved(info : Info)
      @resolved_infos[info]
    end

    # TODO: rename as [] and rename [] to info_for or similar?
    def resolved(ctx, node : AST::Node)
      resolved(ctx.type_check[@rf.link][node])
    end

    # TODO: remove this silly alias:
    def resolved_or_unconstrained(ctx, node : AST::Node)
      info = ctx.type_check[@rf.link][node]
      @resolved_infos[info]? || MetaType.unconstrained
    end

    def resolved_self_cap : MetaType
      @is_constructor ? MetaType.cap("ref") : @rf.receiver_cap
    end

    def resolved_self
      MetaType.new(@rf.type).override_cap(resolved_self_cap)
    end

    def each_meta_type(&block)
      yield @rf.receiver
      yield resolved_self
      @resolved_infos.each_value { |mt| yield mt }
    end

    def each_called_func
      @called_funcs.each
    end
  end

  def initialize
    @t_analyses = {} of Program::Type::Link => TypeAnalysis
    @f_analyses = {} of Program::Function::Link => FuncAnalysis
    @map = {} of ReifiedFunction => ForReifiedFunc
    @types = {} of ReifiedType => ForReifiedType
    @invalid_types = Set(ReifiedType).new
    @aliases = {} of ReifiedTypeAlias => ForReifiedTypeAlias
    @unwrapping_set = Set(ReifiedTypeAlias).new
    @has_started = false
  end

  def has_started?; @has_started; end

  def run(ctx)
    @has_started = true

    # First, make sure we know about each type, without type arguments
    # (just so that we know it has initialized its subtype assertions).
    ctx.program.libraries.each do |library|
      library.types.each do |t|
        t_link = t.make_link(library)
        rts = for_type_partial_reifications(ctx, t_link)

        # If there are no partial reifications (thus no type parameters),
        # then run it for the reified type with no arguments.
        for_rt(ctx, t_link) if rts.empty?
      end
    end

    # Now do the main type checking pass in each library.
    ctx.program.libraries.each do |library|
      run_for_library(ctx, library)
    end

    reach_additional_subtype_relationships(ctx)
    reach_additional_subfunc_relationships(ctx)
  end

  def run_for_library(ctx, library)
    # Always evaluate the Main type first, if it's part of this library.
    # TODO: This shouldn't be necessary, but it is right now for some reason...
    # In both execution orders, the ReifiedType and ReifiedFunction for Main
    # are identical, but for some reason the resulting type resolutions for
    # expressions can turn out differently... Need to investigate more after
    # more refactoring and cleanup on the analysis and state for this pass...
    main = nil
    sorted_types = library.types.reject do |t|
      next if main
      next if t.ident.value != "Main"
      main = t
      true
    end
    sorted_types.unshift(main) if main

    # For each function in each type, run with a new instance,
    # unless that function has already been reached with an infer instance.
    # We probably reached most of them already by starting from Main.new,
    # so this second pass just takes care of typechecking unreachable functions.
    # This is also where we take care of typechecking for unused partial
    # reifications of all generic type parameters.
    sorted_types.each do |t|
      t_link = t.make_link(library)
      rts = for_type_partial_reifications(ctx, t_link)

      get_or_create_t_analysis(t_link).each_non_argumented_reified.each do |rt|
        t.functions.each do |f|
          f_link = f.make_link(t_link)
          f_cap_value = f.cap.value
          f_cap_value = "read" if f_cap_value == "box" # TODO: figure out if we can remove this Pony-originating semantic hack
          MetaType::Capability.new_maybe_generic(f_cap_value).each_cap.each do |f_cap|
            for_rf(ctx, rt, f_link, MetaType.new(f_cap)).run
          end
        end
      end
    end

    # Check the assertion list for each type, to confirm that it is a subtype
    # of any it claimed earlier, which we took on faith and now verify.
    @types.each(&.last.analysis.subtyping.check_and_clear_assertions(ctx))
  end

  def reach_additional_subtype_relationships(ctx)
    # Keep looping as long as the keep_going variable gets set to true in
    # each iteration of the loop by at least one item in the subtype topology
    # changing in one of the deeply nested loops.
    keep_going = true
    while keep_going
      keep_going = false

      # For each abstract type in the program that we have analyzed...
      # (this should be all of the abstract types in the program)
      @t_analyses.each do |t_link, t_analysis|
        next unless t_link.is_abstract?

        # For each "fully baked" reification of that type we have checked...
        # (this should include all reifications reachable from any defined
        # function, though not necessarily all reachable from Main.new)
        # TODO: Should we be limiting to only paths reachable from Main.new?
        t_analysis.each_reached_fully_reified.each do |rt|
          rt_analysis = self[rt]

          # Store the array of all known complete subtypes that have been
          # tested by any defined code in the program.
          # TODO: Should we be limiting to only paths reachable from Main.new?
          each_known_complete_subtype =
            rt_analysis.each_known_complete_subtype(ctx).to_a

          # For each abstract type in that subtypes list...
          each_known_complete_subtype.each do |subtype_rt|
            next unless subtype_rt.link.is_abstract?
            subtype_rt_analysis = self[subtype_rt]

            # For each other/distinct type in that subtypes list...
            each_known_complete_subtype.each do |other_subtype_rt|
              next if other_subtype_rt == subtype_rt

              # Check if the first subtype is a supertype of the other subtype.
              # For example, if Foo and Bar are both used as subtypes of Any
              # in the program, we check here if Foo is a subtype of Bar,
              # or in another iteration, if Bar is a subtype of Foo.
              #
              # This lets us be sure that later trait mapping for the runtime
              # knows about the relationship of types which may be matched at
              # runtime after having been "carried" as a common supertype.
              #
              # If our test here has changed the topology of known subtypes,
              # then we need to keep going in our overall iteration, since
              # we need to uncover other transitive relationships at deeper
              # levels of transitivity until there is nothing left to uncover.
              orig_size = subtype_rt_analysis.each_known_subtype.size
              subtype_rt_analysis.is_supertype_of?(ctx, other_subtype_rt)
              keep_going = true \
                if orig_size != subtype_rt_analysis.each_known_subtype.size
            end
          end
        end
      end
    end
  end

  def reach_additional_subfunc_relationships(ctx)
    # For each abstract type in the program that we have analyzed...
    # (this should be all of the abstract types in the program)
    @t_analyses.each do |t_link, t_analysis|
      t = t_link.resolve(ctx)
      next unless t_link.is_abstract?

      # For each "fully baked" reification of that type we have checked...
      # (this should include all reifications reachable from any defined
      # function, though not necessarily all reachable from Main.new)
      # TODO: Should we be limiting to only paths reachable from Main.new?
      t_analysis.each_reached_fully_reified.each do |rt|

        # For each known complete subtypes that have been established
        # by testing via some code path in the program thus far...
        # TODO: Should we be limiting to only paths reachable from Main.new?
        self[rt].each_known_complete_subtype(ctx).each do |subtype_rt|

          # For each function in the abstract type and its
          # corresponding function that is required to be in the subtype...
          t.functions.each do |f|
            f_link = f.make_link(rt.link)
            subtype_f_link = f.make_link(subtype_rt.link)

            # For each reification of that function in the abstract type.
            self[f_link].each_reified_func(rt).each do |rf|

              # Reach the corresponding concrete reification in the subtype.
              # This ensures that we have reached the correct reification(s)
              # of each concrete function we may call via an abstract trait.
              for_rf = for_rf(ctx, subtype_rt, subtype_f_link, rf.receiver.cap_only).tap(&.run)
            end
          end
        end
      end
    end
  end

  def [](t_link : Program::Type::Link)
    @t_analyses[t_link]
  end

  def []?(t_link : Program::Type::Link)
    @t_analyses[t_link]?
  end

  def [](f_link : Program::Function::Link)
    @f_analyses[f_link]
  end

  def []?(f_link : Program::Function::Link)
    @f_analyses[f_link]?
  end

  protected def get_or_create_t_analysis(t_link : Program::Type::Link)
    @t_analyses[t_link] ||= TypeAnalysis.new(t_link)
  end

  protected def get_or_create_f_analysis(ctx, f_link : Program::Function::Link)
    @f_analyses[f_link] ||= FuncAnalysis.new(f_link, ctx.pre_infer[f_link], ctx.alt_infer[f_link])
  end

  def [](rf : ReifiedFunction)
    @map[rf].analysis
  end

  def []?(rf : ReifiedFunction)
    @map[rf]?.try(&.analysis)
  end

  def [](rt : ReifiedType)
    @types[rt].analysis
  end

  def []?(rt : ReifiedType)
    @types[rt]?.try(&.analysis)
  end

  # This is only for use in testing.
  def test_simple!(ctx, source, t_name, f_name)
    t_link = ctx.namespace[source][t_name].as(Program::Type::Link)
    t = t_link.resolve(ctx)
    f = t.find_func!(f_name)
    f_link = f.make_link(t_link)
    rt = self[t_link].no_args
    rf = self[f_link].each_reified_func(rt).first
    infer = self[rf]
    {t, f, infer}
  end

  def for_type_partial_reifications(ctx, t_link)
    alt_infer = ctx.alt_infer[t_link]

    type_params = alt_infer.type_params
    return [] of ReifiedType if type_params.empty?

    params_partial_reifications =
      type_params.each_with_index.map do |(param, index)|
        bound_span = alt_infer.type_param_bound_spans[index].transform_mt(&.cap_only)

        bound_span_inner = bound_span.inner
        raise NotImplementedError.new(bound_span.inspect) \
          unless bound_span_inner.is_a?(AltInfer::Span::Terminal)

        bound_mt = bound_span_inner.meta_type

        # TODO: Refactor the partial_reifications to return cap only already.
        caps = bound_mt.partial_reifications.map(&.cap_only)

        # Return the list of MetaTypes that partially reify the bound;
        # that is, a list that constitutes every possible cap substitution.
        {param, bound_mt, caps}
      end

    substitution_sets = [[] of {TypeParam, MetaType, MetaType}]
    params_partial_reifications.each do |param, bound_mt, caps|
      substitution_sets = substitution_sets.flat_map do |pairs|
        caps.map { |cap| pairs + [{param, bound_mt, cap}] }
      end
    end

    substitution_sets.map do |substitutions|
      # TODO: Simplify/refactor in relation to code above
      substitutions_map = {} of TypeParam => MetaType
      substitutions.each do |param, bound, cap_mt|
        substitutions_map[param] = MetaType.new_type_param(param).intersect(cap_mt)
      end

      args = substitutions_map.map(&.last.substitute_type_params(substitutions_map))

      for_rt(ctx, t_link, args).reified
    end
  end

  def for_func_simple(ctx : Context, source : Source, t_name : String, f_name : String)
    t_link = ctx.namespace[source][t_name].as(Program::Type::Link)
    f = t_link.resolve(ctx).find_func!(f_name)
    f_link = f.make_link(t_link)
    for_func_simple(ctx, t_link, f_link)
  end

  def for_func_simple(ctx : Context, t_link : Program::Type::Link, f_link : Program::Function::Link)
    f = f_link.resolve(ctx)
    for_rf(ctx, for_rt(ctx, t_link).reified, f_link, MetaType.cap(f.cap.value))
  end

  # TODO: remove this cheap hacky alias somehow:
  def for_rf_existing!(rf)
    @map[rf]
  end

  def for_rf(
    ctx : Context,
    rt : ReifiedType,
    f : Program::Function::Link,
    cap : MetaType,
  ) : ForReifiedFunc
    mt = MetaType.new(rt).override_cap(cap)
    rf = ReifiedFunction.new(rt, f, mt)
    @map[rf] ||= (
      f_analysis = get_or_create_f_analysis(ctx, f)
      refer_type = ctx.refer_type[f]
      classify = ctx.classify[f]
      type_context = ctx.type_context[f]
      for_rt = for_rt(ctx, rt.link, rt.args)
      ForReifiedFunc.new(ctx, f_analysis, ReifiedFuncAnalysis.new(ctx, rf), for_rt, rf, refer_type, classify, type_context)
      .tap { f_analysis.observe_reified_func(rf) }
    )
  end

  def for_rt(
    ctx : Context,
    rt : ReifiedType,
    type_args : Array(MetaType) = [] of MetaType
  )
    # Sanity check - the reified type shouldn't have any args yet.
    raise "already has type args: #{rt.inspect}" unless rt.args.empty?

    for_rt(ctx, rt.link, type_args)
  end

  def for_rt(
    ctx : Context,
    link : Program::Type::Link,
    type_args : Array(MetaType) = [] of MetaType
  ) : ForReifiedType
    type_args = type_args.map(&.simplify(ctx))
    rt = ReifiedType.new(link, type_args)
    @types[rt]? || (
      refer_type = ctx.refer_type[link]
      ft = @types[rt] = ForReifiedType.new(ctx, ReifiedTypeAnalysis.new(rt), rt, refer_type)
      ft.tap(&.initialize_assertions(ctx))
      .tap { |ft| get_or_create_t_analysis(link).observe_reified_type(ctx, rt) }
    )
  end

  def for_rt_alias(
    ctx : Context,
    link : Program::TypeAlias::Link,
    type_args : Array(MetaType) = [] of MetaType
  ) : ForReifiedTypeAlias
    refer_type = ctx.refer_type[link]
    rt_alias = ReifiedTypeAlias.new(link, type_args)
    @aliases[rt_alias] ||= ForReifiedTypeAlias.new(ctx, rt_alias, refer_type)
  end

  def self.unwrap_alias(ctx : Context, rt_alias : ReifiedTypeAlias) : MetaType?
    alt_infer = ctx.alt_infer[rt_alias.link]
    alt_infer
      .deciding_type_args_of(rt_alias.args, alt_infer.target_span)
      .try(&.final_mt!(ctx))
  end

  # TODO: Get rid of this
  protected def for_rt!(rt)
    @types[rt]
  end

  def ensure_rt(ctx : Context, rt : ReifiedType)
    return true if @types.has_key?(rt)
    return false if @invalid_types.includes?(rt)

    if rt_valid?(ctx, rt)
      # TODO: shouldn't have to pull the rt apart here and reassemble inside.
      for_rt(ctx, rt.link, rt.args)
      true
    else
      @invalid_types.add(rt)
      false
    end
  end

  def rt_valid?(ctx : Context, rt : ReifiedType)
    rt_defn = rt.defn(ctx)
    type_params = AST::Extract.type_params(rt_defn.params)

    # The minimum number of params is the number that don't have defaults.
    # The maximum number of params is the total number of them.
    type_params_min = type_params.select { |(_, _, default)| !default }.size
    type_params_max = type_params.size

    # Handle the case where no type args are given.
    if rt.args.empty?
      if type_params_min == 0
        return true
      else
        return false
      end
    end

    # Check number of type args against number of type params.
    if rt.args.size > type_params_max
      return false
    elsif rt.args.size < type_params_min
      return false
    end

    # Unwrap any type aliases present in the first layer of each type arg.
    unwrapped_args = rt.args.map { |arg|
      arg.substitute_each_type_alias_in_first_layer { |rta|
        TypeCheck.unwrap_alias(ctx, rta).not_nil!
      }
    }

    # Check each type arg against the bound of the corresponding type param.
    unwrapped_args.each_with_index do |arg, index|
      alt_infer = ctx.alt_infer[rt.link]
      param_bound_span = alt_infer.deciding_type_args_of(unwrapped_args,
        alt_infer.type_param_bound_spans[index]
      )
      return false unless param_bound_span

      # TODO: move this unwrapping code to a common place?
      param_bound_span_inner = param_bound_span.inner
      param_bound_mt =
        case param_bound_span_inner
        when AltInfer::Span::Terminal
          param_bound_span_inner.meta_type
        when AltInfer::Span::ErrorPropagate
          return false
        else
          raise NotImplementedError.new(param_bound_span.inspect)
        end

      return false if !arg.satisfies_bound?(ctx, param_bound_mt)
    end

    true
  end

  def validate_type_args(
    ctx : Context,
    infer : (ForReifiedFunc | ForReifiedType),
    node : AST::Node,
    mt : MetaType,
  )
    return unless mt.singular? # this skip partially reified type params
    rt = mt.single!
    rt_defn = rt.defn(ctx)
    type_params = AST::Extract.type_params(rt_defn.params)
    arg_terms = node.is_a?(AST::Qualify) ? node.group.terms : [] of AST::Node

    # The minimum number of params is the number that don't have defaults.
    # The maximum number of params is the total number of them.
    type_params_min = type_params.select { |(_, _, default)| !default }.size
    type_params_max = type_params.size

    if rt.args.empty?
      if type_params_min == 0
        # If there are no type args or type params there's nothing to check.
        return
      else
        # If there are type params but no type args we have a problem.
        ctx.error_at node, "This type needs to be qualified with type arguments", [
          {rt_defn.params.not_nil!,
            "these type parameters are expecting arguments"}
        ]
        return
      end
    end

    # If this is an identifier referencing a different type, skip it;
    # it will have been validated at its referent location, and trying
    # to validate it here would break because we don't have the Qualify node.
    return if node.is_a?(AST::Identifier) \
      && !infer.classify.further_qualified?(node)

    raise "inconsistent arguments" if arg_terms.size != rt.args.size

    # Check number of type args against number of type params.
    if rt.args.empty?
      ctx.error_at node, "This type needs to be qualified with type arguments", [
        {rt_defn.params.not_nil!, "these type parameters are expecting arguments"}
      ]
      return
    elsif rt.args.size > type_params_max
      params_pos = (rt_defn.params || rt_defn.ident).pos
      ctx.error_at node, "This type qualification has too many type arguments", [
        {params_pos, "at most #{type_params_max} type arguments were expected"},
      ].concat(arg_terms[type_params_max..-1].map { |arg|
        {arg.pos, "this is an excessive type argument"}
      })
      return
    elsif rt.args.size < type_params_min
      params = rt_defn.params.not_nil!
      ctx.error_at node, "This type qualification has too few type arguments", [
        {params.pos, "at least #{type_params_min} type arguments were expected"},
      ].concat(params.terms[rt.args.size..-1].map { |param|
        {param.pos, "this additional type parameter needs an argument"}
      })
      return
    end

    # Check each type arg against the bound of the corresponding type param.
    arg_terms.zip(rt.args).each_with_index do |(arg_node, arg), index|
      # Skip checking type arguments that contain type parameters.
      next unless arg.type_params.empty?

      arg = arg.simplify(ctx)

      param_bound = for_rt(ctx, rt.link, rt.args).get_type_param_bound(index)
      next unless param_bound

      unless arg.satisfies_bound?(ctx, param_bound)
        bound_pos =
          rt_defn.params.not_nil!.terms[index].as(AST::Group).terms.last.pos
        ctx.error_at arg_node,
          "This type argument won't satisfy the type parameter bound", [
            {bound_pos, "the type parameter bound is #{param_bound.show_type}"},
            {arg_node.pos, "the type argument is #{arg.show_type}"},
          ]
      end
    end
  end

  module TypeExprEvaluation
    abstract def reified : (ReifiedType | ReifiedTypeAlias)

    def reified_type(*args)
      ctx.type_check.for_rt(ctx, *args).reified
    end

    def reified_type_alias(*args)
      ctx.type_check.for_rt_alias(ctx, *args).reified
    end

    # An identifier type expression must refer_type to a type.
    def type_expr(node : AST::Identifier, refer_type, receiver = nil) : MetaType?
      ref = refer_type[node]?
      case ref
      when Refer::Self
        receiver || MetaType.new(reified)
      when Refer::Type
        MetaType.new(reified_type(ref.link))
      when Refer::TypeAlias
        MetaType.new_alias(reified_type_alias(ref.link_alias))
      when Refer::TypeParam
        lookup_type_param(ref, receiver)
      when nil
        case node.value
        when "iso", "trn", "val", "ref", "box", "tag", "non"
          MetaType.new(MetaType::Capability.new(node.value))
        when "any", "alias", "send", "share", "read"
          MetaType.new(MetaType::Capability.new_generic(node.value))
        else
          ctx.error_at node, "This type couldn't be resolved"
          nil
        end
      else
        raise NotImplementedError.new(ref.inspect)
      end
    end

    # An relate type expression must be an explicit capability qualifier.
    def type_expr(node : AST::Relate, refer_type, receiver = nil) : MetaType?
      if node.op.value == "'"
        cap_ident = node.rhs.as(AST::Identifier)
        case cap_ident.value
        when "aliased"
          type_expr(node.lhs, refer_type, receiver).try(&.simplify(ctx).alias)
        else
          cap = type_expr(cap_ident, refer_type, receiver)
          type_expr(node.lhs, refer_type, receiver).try(&.simplify(ctx).override_cap(cap)) if cap
        end
      elsif node.op.value == "->"
        lhs_mt = type_expr(node.lhs, refer_type, receiver)
        rhs_mt = type_expr(node.rhs, refer_type, receiver)
        rhs_mt.simplify(ctx).viewed_from(lhs_mt) if lhs_mt && rhs_mt
      elsif node.op.value == "->>"
        lhs_mt = type_expr(node.lhs, refer_type, receiver)
        rhs_mt = type_expr(node.rhs, refer_type, receiver)
        rhs_mt.simplify(ctx).extracted_from(lhs_mt) if lhs_mt && rhs_mt
      else
        raise NotImplementedError.new(node.to_a.inspect)
      end
    end

    # A "|" group must be a union of type expressions, and a "(" group is
    # considered to be just be a single parenthesized type expression (for now).
    def type_expr(node : AST::Group, refer_type, receiver = nil) : MetaType?
      if node.style == "|"
        mts = node.terms
          .select { |t| t.is_a?(AST::Group) && t.terms.size > 0 }
          .compact_map { |t| type_expr(t, refer_type, receiver).as(MetaType) }

        # Bail out if any of the inner nodes were nil.
        return nil if mts.size < node.terms.size

        MetaType.new_union(mts)
      elsif node.style == "(" && node.terms.size == 1
        type_expr(node.terms.first, refer_type, receiver)
      else
        raise NotImplementedError.new(node.to_a.inspect)
      end
    end

    # A "(" qualify is used to add type arguments to a type.
    def type_expr(node : AST::Qualify, refer_type, receiver = nil) : MetaType?
      raise NotImplementedError.new(node.to_a) unless node.group.style == "("

      target = type_expr(node.term, refer_type, receiver)
      args = node.group.terms.compact_map do |t|
        mt = type_expr(t, refer_type, receiver)
        resolve_type_param_parent_links(mt).as(MetaType) if mt
      end

      # Bail out if any of the inner nodes were nil.
      return nil unless target
      return nil if args.size < node.group.terms.size

      target_inner = target.inner
      if target_inner.is_a?(MetaType::Nominal) \
      && target_inner.defn.is_a?(ReifiedTypeAlias)
        MetaType.new(reified_type_alias(target_inner.defn.as(ReifiedTypeAlias).link, args))
      else
        cap = begin target.cap_only rescue nil end
        mt = MetaType.new(reified_type(target.single!, args))
        mt = mt.override_cap(cap) if cap
        mt
      end
    end

    # All other AST nodes are unsupported as type expressions.
    def type_expr(node : AST::Node, refer_type, receiver = nil) : MetaType?
      raise NotImplementedError.new(node.to_a)
    end

    # TODO: Can we do this more eagerly? Chicken and egg problem.
    # Can every TypeParam contain the parent_rt from birth, so we can avoid
    # the cost of scanning and substituting them here later?
    # It's a chicken-and-egg problem because the parent_rt may contain
    # references to type params in its type arguments, which means those
    # references have to exist somehow before the parent_rt is settled,
    # but then that changes the parent_rt which needs to be embedded in them.
    def resolve_type_param_parent_links(mt : MetaType) : MetaType
      substitutions = {} of TypeParam => MetaType
      mt.type_params.each do |type_param|
        next if type_param.parent_rt
        next if type_param.ref.parent_link != reified.link

        scoped_type_param = TypeParam.new(type_param.ref, reified)
        substitutions[type_param] = MetaType.new_type_param(scoped_type_param)
      end

      mt = mt.substitute_type_params(substitutions) if substitutions.any?

      mt
    end
  end

  class ForReifiedTypeAlias
    include TypeExprEvaluation

    private getter ctx : Context
    getter reified : ReifiedTypeAlias
    protected getter refer_type : ReferType::Analysis

    def initialize(@ctx, @reified, @refer_type)
    end

    def lookup_type_param(ref : Refer::TypeParam, receiver = nil)
      raise NotImplementedError.new(ref) if ref.parent_link != reified.link

      # Lookup the type parameter on self type and return the arg if present
      arg = reified.args[ref.index]?
      return arg if arg

      # Use the default type argument if this type parameter has one.
      ref_default = ref.default
      return type_expr(ref_default, refer_type) if ref_default

      raise "halt" if reified.is_complete?(ctx)

      # Otherwise, return it as an unreified type parameter nominal.
      MetaType.new_type_param(TypeParam.new(ref))
    end
  end

  class ForReifiedType
    include TypeExprEvaluation

    private getter ctx : Context
    getter analysis : ReifiedTypeAnalysis
    getter reified : ReifiedType
    protected getter refer_type : ReferType::Analysis

    def initialize(@ctx, @analysis, @reified, @refer_type)
      @type_param_refinements = {} of Refer::TypeParam => Array(MetaType)
    end

    def initialize_assertions(ctx)
      reified_defn = reified.defn(ctx)
      reified_defn.functions.each do |f|
        next unless f.has_tag?(:is)

        f_link = f.make_link(reified.link)
        trait_mt = type_expr(f.ret.not_nil!, ctx.refer_type[f_link])
        next unless trait_mt

        trait_rt = trait_mt.single!
        ctx.type_check.for_rt!(trait_rt).analysis.subtyping.assert(reified, f.ident.pos)
      end
    end

    # TODO: caching here?
    def type_params_and_type_args(ctx)
      type_params =
        @reified.link.resolve(ctx).params.try(&.terms.map { |type_param|
          ident = AST::Extract.type_param(type_param).first
          ref = @refer_type[ident]?
          Infer::TypeParam.new(ref.as(Refer::TypeParam))
        }) || [] of Infer::TypeParam

      type_args = @reified.args.map { |arg|
        arg.substitute_each_type_alias_in_first_layer { |rta|
          TypeCheck.unwrap_alias(ctx, rta).not_nil!
        }
      }

      type_params.zip(type_args)
    end

    def type_arg_for_type_param(ctx, type_param : TypeParam) : MetaType?
      index =
        @reified.link.resolve(ctx).params.try(&.terms.index { |type_param_ast|
          ident = AST::Extract.type_param(type_param_ast).first
          @refer_type[ident]? == type_param.ref
        })

      @reified.args[index] if index
    end

    def get_type_param_bound(index : Int32)
      param_ident = AST::Extract.type_param(reified.defn(ctx).params.not_nil!.terms[index]).first
      param_bound_node = refer_type[param_ident].as(Refer::TypeParam).bound

      type_expr(param_bound_node.not_nil!, refer_type, nil)
    end

    def lookup_type_param(ref : Refer::TypeParam, receiver = nil)
      raise NotImplementedError.new(ref) if ref.parent_link != reified.link

      # Lookup the type parameter on self type and return the arg if present
      arg = reified.args[ref.index]?
      return arg if arg

      # Use the default type argument if this type parameter has one.
      ref_default = ref.default
      return type_expr(ref_default, refer_type) if ref_default

      raise "halt" if reified.is_complete?(ctx)

      # Otherwise, return it as an unreified type parameter nominal.
      MetaType.new_type_param(TypeParam.new(ref))
    end

    def lookup_type_param_bound(type_param : TypeParam)
      parent_rt = type_param.parent_rt
      if parent_rt && parent_rt != reified
        raise NotImplementedError.new(parent_rt) if parent_rt.is_a?(ReifiedTypeAlias)
        return (
          ctx.type_check.for_rt(ctx, parent_rt.link.as(Program::Type::Link), parent_rt.args)
            .lookup_type_param_bound(type_param)
        )
      end

      if type_param.ref.parent_link != reified.link
        raise NotImplementedError.new([reified, type_param].inspect) \
          unless parent_rt
      end

      # Get the MetaType of the declared bound for this type parameter.
      bound : MetaType? = type_expr(type_param.ref.bound, refer_type, nil)
      return unless bound

      # If we have temporary refinements for this type param, apply them now.
      @type_param_refinements[type_param.ref]?.try(&.each { |refine_type|
        # TODO: make this less of a special case, somehow:
        bound = bound.strip_cap.intersect(refine_type.strip_cap).intersect(
          MetaType.new(
            bound.cap_only.inner.as(MetaType::Capability).set_intersect(
              refine_type.cap_only.inner.as(MetaType::Capability)
            )
          )
        )
      })

      bound
    end

    def push_type_param_refinement(ref, refine_type)
      (@type_param_refinements[ref] ||= [] of MetaType) << refine_type
    end

    def pop_type_param_refinement(ref)
      list = @type_param_refinements[ref]
      list.empty? ? @type_param_refinements.delete(ref) : list.pop
    end
  end

  class ForReifiedFunc < Mare::AST::Visitor
    getter f_analysis : FuncAnalysis
    getter analysis : ReifiedFuncAnalysis
    getter for_rt : ForReifiedType
    getter reified : ReifiedFunction
    private getter ctx : Context
    private getter refer_type : ReferType::Analysis
    protected getter classify : Classify::Analysis
    private getter type_context : TypeContext::Analysis

    def initialize(@ctx, @f_analysis, @analysis, @for_rt, @reified, @refer_type, @classify, @type_context)
      @local_idents = Hash(Refer::Local, AST::Node).new
      @local_ident_overrides = Hash(AST::Node, AST::Node).new
      @redirects = Hash(AST::Node, AST::Node).new
      @already_ran = false
      @prevent_reentrance = {} of Info => Int32
      @layers_ignored = [] of Int32
      @layers_accepted = [] of Int32
      @rt_is_complete = @reified.type.is_complete?(ctx).as(Bool)
      @rt_contains_foreign_type_params = @reified.type.args.any? { |arg|
        arg.type_params.any? { |type_param|
          !@f_analysis.alt_infer.type_params.includes?(type_param)
        }
      }.as(Bool)
    end

    def func
      reified.func(ctx)
    end

    def params
      func.params.try(&.terms) || ([] of AST::Node)
    end

    def ret
      # The ident is used as a fake local variable that represents the return.
      func.ident
    end

    # Returns true if the specified type context layer has some conditions
    # that we do not satisfy in our current reification of this function.
    # In such a case, we will ignore that layer and not do typechecking on it,
    # because doing so would run into unsatisfiable combinations of types.
    def ignores_layer?(layer_index : Int32)
      return false if @layers_accepted.includes?(layer_index)
      return true if @layers_ignored.includes?(layer_index)

      layer = @type_context[layer_index]

      should_ignore = !layer.all_positive_conds.all? { |cond|
        cond_info = @f_analysis[cond]
        case cond_info
        when Infer::TypeParamCondition
          type_param = Infer::TypeParam.new(cond_info.refine)
          refine_mt = resolve(ctx, cond_info.refine_type)
          next false unless refine_mt

          type_arg = @for_rt.type_arg_for_type_param(ctx, type_param).not_nil!
          type_arg.satisfies_bound?(ctx, refine_mt)
        # TODO: also handle other conditions?
        else true
        end
      }

      if should_ignore
        @layers_ignored << layer_index
      else
        @layers_accepted << layer_index
      end

      should_ignore
    end

    def filter_span(ctx, info : Info) : MetaType?
      span = @f_analysis.span?(info)
      return MetaType.unconstrained unless span

      # Filter the span by deciding the function capability.
      filtered_span = span
        .deciding_f_cap(
          reified.receiver_cap,
          func.has_tag?(:constructor)
        )

      type_params_and_type_args = @for_rt.type_params_and_type_args(ctx)

      # Filter the span by deciding the type parameter capability.
      if filtered_span && !filtered_span.inner.is_a?(AltInfer::Span::Terminal)
        filtered_span = @for_rt.type_params_and_type_args(ctx)
          .reduce(filtered_span) { |filtered_span, (type_param, type_arg)|
            next unless filtered_span

            filtered_span.deciding_type_param(type_param, type_arg.cap_only)
          }
      end

      # If this is a complete reified type (not partially reified),
      # then also substitute in the type args for each type param.
      if type_params_and_type_args.any?
        substs = type_params_and_type_args.to_h.transform_values(&.strip_cap)

        filtered_span = filtered_span.try(&.transform_mt { |mt|
          mt.substitute_type_params(substs)
        })
      end

      filtered_span.try(&.final_mt!(ctx))
    end

    # TODO: remove this convenience alias:
    def resolve(ctx : Context, ast : AST::Node) : MetaType?
      resolve(ctx, @f_analysis[ast])
    end

    def resolve(ctx : Context, info : Infer::Info) : MetaType?
      # If our type param reification doesn't match any of the conditions
      # for the layer associated with the given info, then
      # we will not do any typechecking here - we just return nil.
      return nil if ignores_layer?(info.layer_index)

      @analysis.resolved_infos[info]? || begin
        mt = info.as_conduit?.try(&.resolve!(ctx, self)) || filter_span(ctx, info)
        @analysis.resolved_infos[info] = mt || MetaType.unconstrained
        return nil unless mt

        okay = type_check_pre(ctx, info, mt)
        type_check(info, mt) if okay

        # Reach any types that are within this MetaType.
        # TODO: Refactor this to take a block instead of returning an Array.
        mt.each_reachable_defn(ctx).each { |rt|
          ctx.type_check.ensure_rt(ctx, rt)
        } if okay

        mt
      end
    end

    # Validate type arguments for FixedSingleton values.
    def type_check_pre(ctx : Context, info : Infer::FixedSingleton, mt : MetaType) : Bool
      ctx.type_check.validate_type_args(ctx, self, info.node, mt)
      true
    end

    # Sometimes print a special case error message for Literal values.
    def type_check_pre(ctx : Context, info : Infer::Literal, mt : MetaType) : Bool
      # If we've resolved to a single concrete type already, move forward.
      return true if mt.singular? && mt.single!.link.is_concrete?

      # If we can't be satisfiably intersected with the downstream constraints,
      # move forward and let the standard type checker error happen.
      constrained_mt = mt.intersect(info.total_downstream_constraint(ctx, self))
      return true if constrained_mt.simplify(ctx).unsatisfiable?

      # Otherwise, print a Literal-specific error that includes peer hints,
      # as well as a call to action to use an explicit numeric type.
      error_info = info.describe_peer_hints(ctx, self)
      error_info.concat(info.describe_downstream_constraints(ctx, self))
      error_info.push({info.pos,
        "and the literal itself has an intrinsic type of #{mt.show_type}"
      })
      error_info.push({Source::Pos.none,
        "Please wrap an explicit numeric type around the literal " \
          "(for example: U64[#{info.pos.content}])"
      })
      ctx.error_at info,
        "This literal value couldn't be inferred as a single concrete type",
        error_info
      false
    end

    # Sometimes print a special case error message for ArrayLiteral values.
    def type_check_pre(ctx : Context, info : Infer::ArrayLiteral, mt : MetaType) : Bool
      # If the array cap is not ref or "lesser", we must recover to the
      # higher capability, meaning all element expressions must be sendable.
      array_cap = mt.cap_only_inner
      unless array_cap.supertype_of?(MetaType::Capability::REF)
        term_mts = info.terms.compact_map { |term| resolve(ctx, term) }
        unless term_mts.all?(&.alias.is_sendable?)
          ctx.error_at info.pos, "This array literal can't have a reference cap of " \
            "#{array_cap.value} unless all of its elements are sendable",
              info.describe_downstream_constraints(ctx, self)
        end
      end

      # Reach the functions we will use during CodeGen.
      array_rt = mt.single!
      ["new", "<<"].each do |f_name|
        f = array_rt.defn(ctx).find_func!(f_name)
        f_link = f.make_link(array_rt.link)
        ctx.type_check.for_rf(ctx, array_rt, f_link, MetaType.cap(f.cap.value)).run
        @analysis.called_funcs.add({info.pos, array_rt, f_link})
      end

      true
    end

    # Check runtime match safety for TypeCondition expressions.
    def type_check_pre(ctx : Context, info : Infer::TypeCondition, mt : MetaType) : Bool
      lhs_mt = resolve(ctx, info.lhs)
      rhs_mt = resolve(ctx, info.rhs)

      # TODO: move that function here into this file/module.
      Infer::TypeCondition.verify_safety_of_runtime_type_match(ctx, info.pos,
        lhs_mt,
        rhs_mt,
        info.lhs.pos,
        info.rhs.pos,
      ) if lhs_mt && rhs_mt

      true
    end
    def type_check_pre(ctx : Context, info : Infer::TypeConditionForLocal, mt : MetaType) : Bool
      lhs_info = @f_analysis[info.refine]
      lhs_info = lhs_info.info if lhs_info.is_a?(Infer::LocalRef)
      rhs_info = info.refine_type
      lhs_mt = resolve(ctx, lhs_info)
      rhs_mt = resolve(ctx, rhs_info)

      # TODO: move that function here into this file/module.
      Infer::TypeCondition.verify_safety_of_runtime_type_match(ctx, info.pos,
        lhs_mt,
        rhs_mt,
        lhs_info.as(Infer::NamedInfo).first_viable_constraint_pos,
        rhs_info.pos,
      ) if lhs_mt && rhs_mt

      true
    end

    # Reach the particular reification of the function called in a FromCall.
    def type_check_pre(ctx : Context, info : Infer::FromCall, mt : MetaType) : Bool
      # Skip further checks if any foreign type params are present.
      # TODO: Move these checks to an non-reified function analysis pass
      # that operates on the spans instead of the fully resolved/reified types?
      return true if @rt_contains_foreign_type_params

      receiver_mt = resolve(ctx, info.lhs)
      return false unless receiver_mt

      call_defns = receiver_mt.find_callable_func_defns(ctx, self, info.member)

      problems = [] of {Source::Pos, String}
      call_defns.each do |(call_mti, call_defn, call_func)|
        call_mt = MetaType.new(call_mti)
        next unless call_defn
        next unless call_func
        call_func_link = call_func.make_link(call_defn.link)

        # Keep track that we called this function.
        @analysis.called_funcs.add({info.pos, call_defn, call_func_link})

        # Determine the correct capability to reify, checking for cap errors.
        reify_cap, autorecover_needed =
          info.follow_call_check_receiver_cap(ctx, self.func, call_mt, call_func, problems)

        # Check the number of arguments.
        info.follow_call_check_args(ctx, self, call_func, problems)

        # Reach the reified function we are calling, with the right reify_cap,
        # and also get its analysis in case we need to for further checks.
        other_analysis =
          ctx.type_check.for_rf(ctx, call_defn, call_func_link, reify_cap)
            .tap(&.run)
            .analysis

        # Check if auto-recovery of the receiver is possible.
        if autorecover_needed
          ret_mt = other_analysis.ret_resolved
          info.follow_call_check_autorecover_cap(ctx, self, call_func, ret_mt)
        end
      end
      ctx.error_at info,
        "This function call doesn't meet subtyping requirements", problems \
          unless problems.empty?

      true
    end

    # Reach the underlying field "function" of a Field.
    def type_check_pre(ctx : Context, info : Infer::FieldRead, mt : MetaType) : Bool
      type_check_pre(ctx, info.field, mt)
    end
    def type_check_pre(ctx : Context, info : Infer::Field, mt : MetaType) : Bool
      field_func = @reified.type.defn(ctx).functions.find do |f|
        f.ident.value == info.name && f.has_tag?(:field)
      end.not_nil!
      field_func_link = field_func.make_link(@reified.type.link)

      # Keep track that we touched the "function" of the field_func.
      @analysis.called_funcs.add({info.pos, @reified.type, field_func_link})

      # Get the visitor for the field_func, possibly creating and running it.
      ctx.type_check.for_rf(
        ctx,
        @reified.type,
        field_func_link,
        @analysis.resolved_self_cap
      ).tap(&.run)

      true
    end

    # Reach the reflectable functions assocaited with a ReflectionOfType.
    def type_check_pre(ctx : Context, info : Infer::ReflectionOfType, mt : MetaType) : Bool
      reflection_mt = mt
      reflection_rt = mt.single!
      reflect_mt = reflection_rt.args.first
      return true if reflect_mt.type_params.any? # TODO: can we handle unreified type param cases?
      reflect_rt = reflect_mt.single!

      # Reach all functions that might possibly be reflected.
      reflect_rt.defn(ctx).functions.each do |f|
        next if f.has_tag?(:hygienic)
        next if f.body.nil?
        next if f.ident.value.starts_with?("_")
        f_link = f.make_link(reflect_rt.link)
        MetaType::Capability.new_maybe_generic(f.cap.value).each_cap.each do |f_cap|
          ctx.type_check.for_rf(ctx, reflect_rt, f_link, MetaType.new(f_cap)).tap(&.run)
        end
        @analysis.called_funcs.add({info.pos, reflect_rt, f_link})
      end

      true
    end

    # Other types of Info nodes do not have extra type checks.
    def type_check_pre(ctx : Context, info : Infer::Info, mt : MetaType) : Bool
      true # There is nothing extra here.
    end

    def type_check(info : Infer::DynamicInfo, meta_type : Infer::MetaType)
      return if info.downstreams_empty?

      # TODO: print a different error message when the downstream constraints are
      # internally conflicting, even before adding this meta_type into the mix.
      if !meta_type.ephemeralize.within_constraints?(ctx, [
        info.total_downstream_constraint(ctx, self)
      ])
        extra = info.describe_downstream_constraints(ctx, self)
        extra << {info.pos,
          "but the type of the #{info.described_kind} was #{meta_type.show_type}"}
        this_would_be_possible_if = info.this_would_be_possible_if
        extra << this_would_be_possible_if if this_would_be_possible_if

        ctx.error_at info.downstream_use_pos, "The type of this expression " \
          "doesn't meet the constraints imposed on it",
            extra
      end

      # If aliasing makes a difference, we need to evaluate each constraint
      # that has nonzero aliases with an aliased version of the meta_type.
      if meta_type != meta_type.strip_ephemeral.alias
        meta_type_alias = meta_type.strip_ephemeral.alias

        # TODO: Do we need to do anything here to weed out union types with
        # differing capabilities of compatible terms? Is it possible that
        # the type that fulfills the total_downstream_constraint is not compatible
        # with the ephemerality requirement, while some other union member is?
        info.downstreams_each.each do |use_pos, other_info, aliases|
          next unless aliases > 0

          constraint = resolve(ctx, other_info).as(Infer::MetaType?)
          next unless constraint

          if !meta_type_alias.within_constraints?(ctx, [constraint])
            extra = info.describe_downstream_constraints(ctx, self)
            extra << {info.pos,
              "but the type of the #{info.described_kind} " \
              "(when aliased) was #{meta_type_alias.show_type}"
            }
            this_would_be_possible_if = info.this_would_be_possible_if
            extra << this_would_be_possible_if if this_would_be_possible_if

            ctx.error_at use_pos, "This aliasing violates uniqueness " \
              "(did you forget to consume the variable?)",
              extra
          end
        end
      end
    end

    # For all other info types we do nothing.
    # TODO: should we do something?
    def type_check(info : Infer::Info, meta_type : Infer::MetaType)
    end

    # This variant lets you eagerly choose the MetaType that a different Info
    # resolves as, with that Info having no say in the matter. Use with caution.
    def resolve_as(ctx : Context, info : Info, meta_type : MetaType) : MetaType
      raise "already resolved #{info}\n" \
        "as #{@analysis.resolved_infos[info].show_type}" \
          if @analysis.resolved_infos.has_key?(info) \
          && @analysis.resolved_infos[info] != meta_type

      @analysis.resolved_infos[info] = meta_type
    end

    # This variant has protection to prevent infinite recursion.
    # It is mainly used by FromCall, since it interacts across reified funcs.
    def resolve_with_reentrance_prevention(ctx : Context, info : Info) : MetaType?
      orig_count = @prevent_reentrance[info]?
      if (orig_count || 0) > 2 # TODO: can we remove this counter and use a set instead of a map?
        kind = info.is_a?(Infer::DynamicInfo) ? " #{info.describe_kind}" : ""
        ctx.error_at info.pos,
          "This#{kind} needs an explicit type; it could not be inferred"
        return nil
      end
      @prevent_reentrance[info] = (orig_count || 0) + 1
      resolve(ctx, info)
      .tap { orig_count ? (@prevent_reentrance[info] = orig_count) : @prevent_reentrance.delete(info) }
    end

    def extra_called_func!(pos, rt, f)
      @analysis.called_funcs.add({pos, rt, f})
    end

    def run
      return if @already_ran
      @already_ran = true

      func_params = func.params
      func_body = func.body

      # TODO: Remove explicit resolve calls here; just resolve everything below.
      resolve(ctx, @f_analysis[func_body]) if func_body
      resolve(ctx, @f_analysis[func_params]) if func_params
      resolve(ctx, @f_analysis[ret])

      @f_analysis.each_info { |info| resolve(ctx, info) }

      # Assign the resolved types to a map for safekeeping.
      # This also has the effect of running some final checks on everything.
      # TODO: Is it possible to remove the simplify calls here?
      # Is it actually a significant performance impact or not?

      if (info = @f_analysis.yield_in_info; info)
        @analysis.yield_in_resolved = resolve(ctx, info).not_nil! # TODO: simplify?
      end
      @analysis.yield_out_resolved = @f_analysis.yield_out_infos.map do |info|
        resolve(ctx, info).as(MetaType?)
      end
      @analysis.ret_resolved = @analysis.resolved_infos[@f_analysis[ret]]

      # Return types of constant "functions" are very restrictive.
      if func.has_tag?(:constant)
        ret_mt = @analysis.ret_resolved
        ret_rt = ret_mt.single?.try(&.defn)
        is_val = ret_mt.cap_only.inner == MetaType::Capability::VAL
        unless is_val && ret_rt.is_a?(ReifiedType) && ret_rt.link.is_concrete? && (
          ret_rt.not_nil!.link.name == "String" ||
          ret_mt.subtype_of?(ctx, MetaType.new_nominal(reified_prelude_type("Numeric"))) ||
          (ret_rt.not_nil!.link.name == "Array" && begin
            elem_mt = ret_rt.args.first
            elem_rt = elem_mt.single?.try(&.defn)
            elem_is_val = elem_mt.cap_only.inner == MetaType::Capability::VAL
            is_val && elem_rt.is_a?(ReifiedType) && elem_rt.link.is_concrete? && (
              elem_rt.not_nil!.link.name == "String" ||
              elem_mt.subtype_of?(ctx, MetaType.new_nominal(reified_prelude_type("Numeric")))
            )
          end)
        )
          ctx.error_at ret, "The type of a constant may only be String, " \
            "a numeric type, or an immutable Array of one of these", [
              {func.ret || func.body || ret, "but the type is #{ret_mt.show_type}"}
            ]
        end
      end

      # Parameters must be sendable when the function is asynchronous,
      # or when it is a constructor with elevated capability.
      require_sendable =
        if func.has_tag?(:async)
          "An asynchronous function"
        elsif func.has_tag?(:constructor) \
        && !resolve(ctx, @f_analysis[ret]).not_nil!.subtype_of?(ctx, MetaType.cap("ref"))
          "A constructor with elevated capability"
        end
      if require_sendable
        func.params.try do |params|

          errs = [] of {Source::Pos, String}
          params.terms.each do |param|
            param_mt = resolve(ctx, @f_analysis[param]).not_nil!

            unless param_mt.is_sendable?
              # TODO: Remove this hacky special case.
              next if param_mt.show_type.starts_with? "CPointer"

              errs << {param.pos,
                "this parameter type (#{param_mt.show_type}) is not sendable"}
            end
          end

          ctx.error_at func.cap.pos,
            "#{require_sendable} must only have sendable parameters", errs \
              unless errs.empty?
        end
      end

      nil
    end

    def reified_prelude_type(name, *args)
      ctx.type_check.for_rt(ctx, @ctx.namespace.prelude_type(name), *args).reified
    end

    def reified_type(*args)
      ctx.type_check.for_rt(ctx, *args).reified
    end

    def reified_type_alias(*args)
      ctx.type_check.for_rt_alias(ctx, *args).reified
    end

    def lookup_type_param(ref, receiver = reified.receiver)
      @for_rt.lookup_type_param(ref, receiver)
    end

    def lookup_type_param_bound(type_param)
      @for_rt.lookup_type_param_bound(type_param)
    end

    def type_expr(node)
      @for_rt.type_expr(node, refer_type, reified.receiver)
    end
  end
end

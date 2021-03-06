module ASTGen
export to_ast
using MLStyle
using JSON

@nospecialize
@inline function ID(x)
    x
end

count = 0

IS_BREAK = Symbol("____Py2Jl____UNSAFE_MANGLE_IS_BREAK")
MANGLE_BASE = Symbol("____Py2Jl____UNSAFE_MANGLE_TMP")

mangle() = begin
    global count
    let name = Symbol(MANGLE_BASE, string(count))
        count = count + 1
        name
    end
end


struct Record end

"""
define a pattern `Record(a, b, c=>c, ...)`
identical to Dict `Dict(a=a, b=b, c=>, ...)`
"""
function MLStyle.pattern_uncall(
    ::Type{Record},
    self,
    tparams::AbstractArray,
    targs::AbstractArray,
    args::AbstractArray,
)
    isempty(tparams) || error("A Record pattern requires no type params.")
    isempty(targs) || error("A Record pattern requires no type arguments.")
    isempty(tparams) || error("A Record pattern requires no type parameters.")
    args = ((arg isa Symbol ?
                let key = QuoteNode(arg)
                    :($key => $arg)
                end : arg)
            for arg in args)
    pat = :($Dict($(args...)))
    self(pat)
end

macro not_implemented_yet()
    :(throw("notimplemented yet"))
end

empty_block = Expr(:block)

function ret_nil(node)
    Expr(:block, node, nothing)
end

"""
Cannot generate python annotations for
the semantics is not the same as Julia's annoations.
"""
function annotate(sym, ty)
    @not_implemented_yet
end

function assign(target, value)
    Expr(:(=), target, value)
end

function (<|)(f, arg)
    f(arg)
end

function gather(args)
    isempty(args) ? nothing :
    length(args) === 1 && args[1] isa Expr ? args[1] :
    Expr(:block, args...)

end

function for_iter(f :: Function, iter_arg, seq, body)
    basic = Expr(:for, assign(iter_arg, seq), body)
    token = mangle()
    result = mangle()
    check_break = Expr(
        :block,
        assign(token, Expr(:call, Ref, false)),
        assign(IS_BREAK, token),
        basic,
        f(token),
    )
end

function for_iter(iter_arg, seq, body)
    for_iter((_) -> nothing, iter_arg, seq, body)
end

function while_loop(f :: Function, cond, body)
    basic = Expr(:while, cond, body)
    token = mangle()
    result = mangle()
    check_break = Expr(:block,
        assign(token, Expr(:call, Ref, false)),
        assign(IS_BREAK, token),
        basic,
        f(token),
    )
end

function while_loop(cond, body)
    while_loop((_) -> nothing, cond, body)
end

function call(fn, args...)
    Expr(:call, fn, args...)
end

function as_global(names...)
    Expr(:global, names...)
end

function get_attr(expr, attr :: Symbol)
    Expr(:., expr, QuoteNode(attr))
end

function break!()
    Expr(:block, assign(get_attr(IS_BREAK, :x), true), Expr(:break))
end

function continue!()
    Expr(:continue)
end

function ifelse(cond, then, else_ :: Nothing)
    Expr(:if, cond, then)
end

function ifelse(cond, then, else_)
    Expr(:if, cond, then, else_)
end


function ifelse(cond, then)
    Expr(:if, cond, then)
end

function isinstance(inst, typs :: Union{Tuple, Vector})
    foldr(typs, init=true) do typ, last
        Expr(:||, isinstance(inst, typ), last)
    end
end

function isinstance(inst, typ)
    Expr(:call, isa, inst, typ)
end

struct Context
    filename
    imports
end

filename(x) = x.filename

function tag_loc(ctx, x)
    _filename = filename(ctx)
    @λ begin
        (if _filename === nothing end &&
         Record(lineno, colno)) -> LineNumberNode(lineno)

        Record(lineno, colno) -> LineNumberNode(lineno, _filename)

        _ -> nothing
    end
end


function trans_block(ctx, seq)
    res = []
    for each in seq
        loc = tag_loc(ctx, each)
        if loc !== nothing
            push!(res, loc)
        end
        push!(res, apply(ctx, each))
    end
    res
end

function fundef(ctx, class, body, kwarg, args, kw_defaults, kwonlyargs, defaults, vararg, fn_ast)
    if kwarg === nothing && isempty(kwonlyargs)
        if isempty(kw_defaults) && isempty(defaults)
            f = @λ Expr(:no_eval, arg, annotation) -> (arg, annotation)
            arg_anno = map(x -> f(apply(ctx, x)), args)
            args = map(first, arg_anno)
            annos = [annotate(arg, anno) for (arg, anno) in arg_anno if anno !== nothing]

            if class == "Lambda"
                Expr(:function, Expr(:tuple, args...), Expr(:block, annos..., apply(ctx, body)))
            else

                body = gather <| trans_block(ctx, body)
                decorator_list = fn_ast[:decorator_list]
                fn_name = Symbol(fn_ast[:name])
                init = Expr(:function, Expr(:call, fn_name, args...), Expr(:block, annos..., body))
                reduce(decorator_list, init=init) do last, decorator
                    decorator = apply(ctx, decorator)
                    wrapped = call(decorator, last)
                    Expr(:(=), fn_name, Expr(:let, empty_block, wrapped))
                end |> ret_nil
            end
        else
            @not_implemented_yet
        end
    else
        @not_implemented_yet
    end
end

function apply(ctx, x)
    _apply = @λ begin
        (num :: Number)  -> num
        (str :: String)  -> str
        (:: Nothing)     -> nothing

        Record(:class => "Module", body) ->
        let body = gather <| trans_block(ctx, body)

            filename === nothing ?
                body                 :
                Expr(:module, true, Symbol(filename), body)
        end

        Record(:class => "Name", id) ->
        Symbol(id)
        Record(:class => "Num", n) -> n

        Record(:class => "List", elts) ->
        Expr(:vect, map(apply, elts)...)

        Record(:class => "Tuple", elts) ->
        Expr(:tuple, map(apply, elts)..., )

        Record(:class => "Return", value) -> Expr(:return, apply(ctx, value))

        Record(:class => "arg", annotation, arg) -> Expr(:no_eval, Symbol(arg), apply(ctx, annotation))

        # FunctionDef
        (Record(class,
                body,
                :args => Record(
                    kwarg,
                    args,
                    kw_defaults,
                    kwonlyargs,
                    defaults,
                    vararg
                )) && fn_ast) -> fundef(ctx, class, body, kwarg, args, kw_defaults, kwonlyargs, defaults, vararg, fn_ast)

        Record(:class   => "Assign", targets, value) ->
        (reduce(targets, init = apply(ctx, value)) do last, target
         Expr(:(=), apply(ctx, target), last)
         end |> ret_nil)

        Record(:class => "AugAssign", target, op, value) -> @not_implemented_yet

        Record(:class => "AnnAssign", target, annotation, value) ->
        (annotate(apply(ctx, target), apply(ctx, annotation)) |>
         target -> assign(target, value)            |>
         ret_nil)

        Record(:class => "For", target, iter, body, orelse) ->
        let target = apply(ctx, target),
            iter = apply(ctx, iter),
            body = gather <| trans_block(ctx, body),
            orelse = gather <| trans_block(ctx, orelse)

            for_iter(target, iter, body) do token
                ifelse(Expr(:call, !, get_attr(token, :x)), orelse)
            end

        end

        Record(:class => "While", test, body, orelse) ->
        let cond = apply(ctx, test),
            body = gather <| trans_block(ctx, body),
            orelse = gather <| trans_block(ctx, orelse)

            while_loop(cond, body) do token
                ifelse(Expr(:call, !, get_attr(token, :x)), orelse)
            end
        end

        Record(:class => "With") -> @not_implemented_yet

        Record(:class => "ClassDef") -> @not_implemented_yet

        Record(:class => "Try", body, handlers, orelse, finalbody) ->
        if !isempty(finalbody) || !isempty(orelse)
            @not_implemented_yet
        else
            ret = Expr(:try, gather <| trans_block(ctx, body))
            if isempty(handlers)
                return ret
            end
            except = mangle()
            args = ret.args
            push!(args, except)
            init = call(throw, except)
            foldr(handlers, init = init) do handler, last
                @match handler begin
                    Record(:type => exc, name, body) =>
                        let exc = apply(ctx, exc),

                            body = gather <| trans_block(ctx, body),

                            tc = isinstance(except, exc),

                            case = name === nothing ? body : gather([
                                assign(name, except),
                                body
                            ])

                            ifelse(tc, body, last)
                        end
                    _ => @error "Unknown python ast."
                end
            end |> it -> push!(args, it)
            ret
        end

        # runtime error
        Record(:class => "Raise", :exc => nothing, :cause => nothing)   -> @not_implemented_yet

        Record(:class => "Raise", exc, :cause => nothing) -> call(throw, apply(ctx, exc))

        Record(:class => "Raise", :exc => _, :cause => _) -> @not_implemented_yet

        Record(:class => "Import") -> @not_implemented_yet

        Record(:class => "ImportFrom") -> @not_implemented_yet

        Record(:class => "Global", names) -> Expr(:global, map(Symbol, names))

        Record(:class => "Pass") -> nothing

        Record(:class => "Break") -> break!()

        Record(:class => "Continue") -> continue!()

        Record(:class => "If", test, body, orelse) ->
        let cond = apply(ctx, test),
            body = gather <| trans_block(ctx, body),
            orelse = gather <| trans_block(ctx, orelse)

            ret_nil <| ifelse(cond, body, orelse)
        end

        Record(:class => "Expr", value) -> ret_nil <| apply(ctx, value)

        Record(:class => "Starred", value) -> Expr(:..., apply(ctx, value))

        Record(:class => "Call", func, args, keywords) ->
        begin
            func = apply(ctx, func)
            args = map(apply, args)
            keywords = [(it[:arg], apply(it[:value])) for it in keywords]
            kw_unpack = [Expr(:..., snd) for (fst, snd) in keywords if fst === nothing]
            kw_args = [Expr(:kw, fst, snd) for (fst, snd) in keywords if fst !== nothing]
            Expr(:call, func, Expr(:parameters, kw_unpack...), args..., kw_args...)
        end
        Record(:class => "BinOp", op, left, right) ->
        let op =  @match op[:class] begin
            # TODO, binary operator in Python cannot be mapped to Julia directly.
            # We should implement Python.(+), Python.(-)...
            "Add"     => (+)
            "Sub"     => (-)
            "Mult"    => (*)
            "Div"     => (/)
            "MatMult" => @not_implemented_yet
            "Mod"     => (%)
            "Pow"     => (^)
            "LShift"  => (<<)
            "RShift"  => (>>)
            "BitOr"   => (|)
            "BitXor"  => xor
            "BitAnd"  => (&)
            "FloorDiv"=> floor ∘ (/)
        end
            call(op, apply(ctx, left), apply(ctx, right))
        end

        # for Python 3.8+
        (Record(:class => "Constant", value)
         || # for Python 3.7- and 3.7
         Record(:class => "NameConstant", value)
         ) -> value

        Record(:class=> "Compare", left, ops, comparators) ->
        foldl(zip(ops, comparators) |> collect, init=apply(ctx, left)) do last, (op, comparator)
            let comparator = apply(ctx, comparator)
                f = @match op[:class] begin
                    #  Eq | NotEq | Lt | LtE | Gt | GtE | Is | IsNot | In | NotIn
                    "Eq" => (==)
                    "NotEq" => (!=)
                    "Lt" => (<)
                    "LtE" => (<=)
                    "Gt"  => (>)
                    "GtE" => (>=)
                    "Is"  => (===)
                    "IsNot" => (!==)
                    "In"    => (in)
                    "NotIn" => (!in)
                end
                :($f($last, $comparator))
            end
        end
        this ->
        let msg = "class: $(this[:class]), attributes: $(keys(this))."
            @match this begin
                Dict(:class=>"Module") => println(:aaa)
                ::T where T => println(T)
            end
            throw(msg)
        end
    end
    _apply(x)
end


"""
Check https://github.com/python/cpython/blob/master/Parser/Python.asdl
for more implementation details.
"""
function to_ast(ctx, python :: Dict)
    apply(ctx, python)
end

@specialize

end

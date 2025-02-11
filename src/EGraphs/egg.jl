# Functional implementation of https://egraphs-good.github.io/
# https://dl.acm.org/doi/10.1145/3434304

using DataStructures

"""
Abstract type representing an [`EGraph`](@ref) analysis,
attaching values from a join semi-lattice domain to
an EGraph
"""
const ClassMem = Dict{Int64,EClass}
const HashCons = Dict{ENode,Int64}
const Analyses = Set{Type{<:AbstractAnalysis}}
const SymbolCache = Dict{Any, Vector{Int64}}



"""
A concrete type representing an [`EGraph`].
See the [egg paper](https://dl.acm.org/doi/pdf/10.1145/3434304)
for implementation details
"""
mutable struct EGraph
    """stores the equality relations over e-class ids"""
    uf::IntDisjointSets
    """map from eclass id to eclasses"""
    classes::ClassMem
    memo::HashCons             # memo
    """worklist for ammortized upwards merging"""
    dirty::Vector{Int64}
    pruned::Vector{Int64}
    root::Int64
    """A vector of analyses associated to the EGraph"""
    analyses::Analyses
    """
    a cache mapping function symbols to e-classes that
    contain e-nodes with that function symbol.
    """
    symcache::SymbolCache
    numclasses::Int
    numnodes::Int
end

EGraph() = EGraph(
    IntDisjointSets(0),
    ClassMem(),
    HashCons(),
    # ParentMem(),
    Vector{Int64}(),
    Vector{Int64}(),
    0,
    Analyses(),
    SymbolCache(),
    0,
    0
)


function EGraph(e)
    g = EGraph()
    rootclass = addexpr!(g, e)
    g.root = rootclass.id
    g
end

function canonicalize(g::EGraph, n::ENode{T}) where T
    new_args = map(x -> find(g, x), n.args)
    ENode{T}(n.head, new_args, n.metadata)
end


function canonicalize!(g::EGraph, n::ENode)
    for i ∈ 1:arity(n)
        n.args[i] = find(g, n.args[i])
    end
    n.hash[] = UInt(0)
    return n
    # n.args = map(x -> find(g, x), n.args)
end


"""
Returns the canonical e-class id for a given e-class.
"""
find(g::EGraph, a::Int64)::Int64 = find_root!(g.uf, a)
find(g::EGraph, a::EClass)::Int64 = find_root!(g.uf, a.id)


function geteclass(g::EGraph, a::Int64)::EClass
    id = find(g, a)
    ec = g.classes[id]
    # @show ec.id id a
    # @assert ec.id == id
    # ec.id = id
    ec
end
# geteclass(g::EGraph, a::EClass)::Int64 = geteclass()


### Definition 2.3: canonicalization
iscanonical(g::EGraph, n::ENode) = n == canonicalize(g, n)
iscanonical(g::EGraph, e::EClass) = find(g, e.id) == e.id

function canonicalize!(g::EGraph, e::EClass)
    e.id = find(g, e.id)
end

"""
Inserts an e-node in an [`EGraph`](@ref)
"""
function add!(g::EGraph, n::ENode)::EClass
    @debug("adding ", n)

    n = canonicalize(g, n)
    if haskey(g.memo, n)
        # return g.classes[g.memo[n]]
        return geteclass(g, g.memo[n])
    end
    @debug(n, " not found in memo")

    id = push!(g.uf) # create new singleton eclass

    for c_id ∈ n.args
        addparent!(g.classes[c_id], n, id)
    end

    g.memo[n] = id

    classdata = EClass(id, ENode[n], Pair{ENode, Int64}[])
    g.classes[id] = classdata
    g.numclasses += 1

    # cache the eclass for the symbol for faster matching
    # sym = n.head
    # if !haskey(g.symcache, sym)
    #     g.symcache[sym] = Int64[]
    # end
    # push!(g.symcache[sym], id)

    # make analyses for new enode
    for an ∈ g.analyses
        if !islazy(an)
            setdata!(classdata, an, make(an, g, n))
            modify!(an, g, id)
        end
    end

    return classdata
end

"""
Recursively traverse an type satisfying the `TermInterface` and insert terms into an
[`EGraph`](@ref). If `e` has no children (has an arity of 0) then directly
insert the literal into the [`EGraph`](@ref).
"""
function addexpr!(g::EGraph, se)::EClass
    # e = preprocess(e)
    # println("========== $e ===========")
    if se isa EClass
        return se
    end
    e = preprocess(se)

    if istree(e)
        args = getargs(e)
        n = length(args)
        class_ids = Vector{Int64}(undef, n)
        for i ∈ 1:n
            # println("child $child")
            @inbounds child = args[i]
            c_eclass = addexpr!(g, child)
            @inbounds class_ids[i] = c_eclass.id
        end
        node = ENode(e, class_ids)
        return add!(g, node)
    end

    return add!(g, ENode(e))
end


# """
# Canonicalize an [`ENode`](@ref) and reset it from the memo.
# """
# function clean_enode!(g::EGraph, t::ENode, to::Int64)
#     # delete!(g.memo, t)
#     # println("removed $t")
#     nt = canonicalize(g, t)
#     # println("added $t $to")
#     g.memo[nt] = to
#     return t
# end

"""
Given an [`EGraph`](@ref) and two e-class ids, set
the two e-classes as equal.
"""
function Base.merge!(g::EGraph, a::Int64, b::Int64)::Int64
    id_a = find(g, a)
    id_b = find(g, b)
    id_a ∈ g.pruned && return id_a
    id_b ∈ g.pruned && return id_b
     
    id_a == id_b && return id_a
    to = union!(g.uf, id_a, id_b)

    @debug "merging" id_a id_b

    from = (to == id_a) ? id_b : id_a

    push!(g.dirty, to)

    from_class = g.classes[from]
    to_class = g.classes[to]
    to_class.id = to

    # I (was) the troublesome line!
    g.classes[to] = union(to_class, from_class)
    delete!(g.classes, from)
    g.numclasses -= 1

    return to
end

function in_same_class(g::EGraph, a, b)
    find(g, a) == find(g, b)
end

function prune!(g::EGraph, a::Int64, b::EClass)
    id_a = find(g, a)
    # union!(g.uf, id_a, b.id)
    b.id = id_a
    g.classes[id_a] = b
    push!(g.dirty, id_a)
    push!(g.pruned, id_a)
    return id_a
end

"""
This function restores invariants and executes
upwards merging in an [`EGraph`](@ref). See
the [egg paper](https://dl.acm.org/doi/pdf/10.1145/3434304)
for more details.
"""
function rebuild!(g::EGraph)
    while !isempty(g.dirty)
        # todo = unique([find(egraph, id) for id ∈ egraph.dirty])
        todo = unique(g.dirty)
        empty!(g.dirty)
        for x ∈ todo
            repair!(g, x)
        end
    end

    g.pruned = unique([find(g,id) for id ∈ g.pruned])
    # for (node, id) ∈ egraph.memo
    #     egraph.memo[node] = find(egraph, id)
    # #     sym = node.head
    # #     if !haskey(egraph.symcache, sym)
    # #         egraph.symcache[sym] = Int64[]
    # #     end
    # #     push!(egraph.symcache[sym], id)
    # end
    # for (sym, ids) ∈ egraph.symcache
    #     egraph.symcache[sym] = unique(ids .|> x -> find(egraph, x))
    # end

    if g.root != 0
        g.root = find(g, g.root)
    end

    # for i ∈ 1:length(egraph.uf)
    #     find_root!(egraph.uf, i)
    # end
    # INVARIANTS ASSERTIONS
    # for (id, c) ∈  egraph.classes
    #     # ecdata.nodes = map(n -> canonicalize(egraph.uf, n), ecdata.nodes)
    #     println(id, "=>", c.id)
    #     @assert(id == c.id)
    #     # for an ∈ egraph.analyses
    #     #     if haskey(an, id)
    #     #         @assert an[id] == mapreduce(x -> make(an, x), (x, y) -> join(an, x, y), c.nodes)
    #     #     end
    #     # end
    
    #     for n ∈ c
    #         println(n)
    #         println("canon = ", canonicalize(egraph, n))
    #         hr = egraph.memo[canonicalize(egraph, n)]
    #         println(hr)
    #         @assert hr == find(egraph, id)
    #     end
    # end
    # display(egraph.classes); println()
    # @show egraph.dirty
end

function repair!(g::EGraph, id::Int64)
    id = find(g, id)
    ecdata = g.classes[id]
    ecdata.id = id
    @debug "repairing " id

    # for (p_enode, p_eclass) ∈ ecdata.parents
    #     clean_enode!(g, p_enode, find(g, p_eclass))
    # end

    new_parents = OrderedDict{ENode,Int64}()

    for (p_enode, p_eclass) ∈ ecdata.parents
        p_enode = canonicalize!(g, p_enode)
        # deduplicate parents
        if haskey(new_parents, p_enode)
            @debug "merging classes" p_eclass (new_parents[p_enode])
            merge!(g, p_eclass, new_parents[p_enode])
        end
        n_id = find(g, p_eclass)
        g.memo[p_enode] = n_id 
        new_parents[p_enode] = n_id 
    end
    ecdata.parents = collect(new_parents)
    @debug "updated parents " id g.parents[id]

    # ecdata.nodes = map(n -> canonicalize(g.uf, n), ecdata.nodes)

    # Analysis invariant maintenance
    for an ∈ g.analyses
        hasdata(ecdata, an) && modify!(an, g, id)
        # modify!(an, id)
        # id = find(g, id)
        for (p_enode, p_id) ∈ ecdata.parents
            # p_eclass = find(g, p_eclass)
            p_eclass = geteclass(g, p_id)
            if !islazy(an) && !hasdata(p_eclass, an)
                setdata!(p_eclass, an, make(an, g, p_enode))
            end
            if hasdata(p_eclass, an)
                p_data = getdata(p_eclass, an)

                new_data = join(an, p_data, make(an, g, p_enode))
                if new_data != p_data
                    setdata!(p_eclass, an, new_data)
                    push!(g.dirty, p_id)
                end
            end
        end
    end

    unique!(ecdata.nodes)

    # ecdata.nodes = map(n -> canonicalize(g.uf, n), ecdata.nodes)

end


"""
Recursive function that traverses an [`EGraph`](@ref) and
returns a vector of all reachable e-classes from a given e-class id.
"""
function reachable(g::EGraph, id::Int64)
    id = find(g, id)
    hist = Int64[id]
    todo = Int64[id]
    while !isempty(todo)
        curr = find(g, pop!(todo))
        for n ∈ g.classes[curr]
            nn = canonicalize(g, n)
            # println("node in reachability is ", n)
            for c_id ∈ nn.args
                if c_id ∉ hist
                    push!(hist, c_id)
                    push!(todo, c_id)
                end
            end
        end
    end

    return hist
end

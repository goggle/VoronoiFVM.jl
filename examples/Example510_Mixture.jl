# # 510: Mixture
# ([source code](SOURCE_URL))
#=

Test mixture diffusion flux. The problem is here that in the flux function we need to
solve a linear system of equations wich calculates the fluxes from the gradients.#
To do so without (heap) allocations can be achieved using StrideArrays, together with the
possibility to have static (compile time) information about the size of the local
arrays to be allocated.

``u_i`` are the species partial pressures, ``\vec N_i`` are the species fluxes.
``D_i^K`` are the Knudsen diffusion coefficients, and ``D^B_{ij}`` are the binary diffusion coefficients.
```math
  -\nabla \cdot \vec N_i =0 \quad (i=1\dots n)\\
  \frac{\vec N_i}{D^K_i} + \sum_{j\neq i}\frac{u_j \vec N_i - u_i \vec N_j}{D^B_{ij}} = -\vec \nabla u_i \quad (i=1\dots n)
```
From this representation, we can derive the matrix ``M=(m_{ij})`` whith
```math
m_{ii}= \frac{1}{D^K_i} + \sum_{j\neq i} \frac{u_j}{D_ij}\\
m_{ij}= -\sum_{j\neq i} \frac{u_i}{D_ij}
```
such that 
```math
	M\begin{pmatrix}
\vec N_1\\
\vdots\\
\vec N_n
\end{pmatrix}
=
\begin{pmatrix}
\vec \nabla u_1\\
\vdots\\
\vec \nabla u_n
\end{pmatrix}
```
In the two point flux finite volume discretization, this results into a corresponding linear system which calculates the discrete edge fluxes from the discrete gradients. 
Here we demonstrate how to implement this in a fast, (heap) allocation free way.

For this purpose, intermediate arrays need to be allocated on the stack with via `StrideArrays.jl` or `MArray` from `StaticArrays.jl`
They need to have the same element type as the unknowns passed to the flux function
(which could be Float64 or some dual number). 
Size information must be static, e.g. a global constant, or, as demonstrated here, a type parameter.
Broadcasting probably should be avoided.

As [documented in  StrideArrays.jl](https://docs.juliahub.com/StrideArrays/Eyl7s/0.1.3/stack_allocation/), use `@gc_preserve` when passing a `StrideArray` as a function parameter.

Alternatively, we can try to avoid StrideArrays.jl and use MArrays together with inlined code.
In this case, one should be aware of [this issue](https://github.com/JuliaArrays/StaticArrays.jl/issues/874),
which requires `@inbounds` e.g. with reverse order loops.

See also [this Discourse thread](https://discourse.julialang.org/t/what-is-stridearrays-jl/97146).

=#

module Example510_Mixture

using Printf
using VoronoiFVM

using ExtendableGrids
using GridVisualize
using LinearAlgebra
using Random
using StrideArraysCore: @gc_preserve, StrideArray, StaticInt, PtrArray
using LinearSolve,ExtendableSparse
using StaticArrays

struct MyData{NSPec}
    DBinary::Symmetric{Float64, Matrix{Float64}}
    DKnudsen::Vector{Float64}
    diribc::Vector{Int}
end

nspec(::MyData{NSpec}) where {NSpec} = NSpec

function flux_strided(f, u, edge, data)
    T = eltype(u)
    M = StrideArray{T}(undef, StaticInt(nspec(data)), StaticInt(nspec(data)))
    au = StrideArray{T}(undef, StaticInt(nspec(data)))
    du = StrideArray{T}(undef, StaticInt(nspec(data)))
    ipiv = StrideArray{Int}(undef, StaticInt(nspec(data)))

    for ispec = 1:nspec(data)
        M[ispec, ispec] = 1.0 / data.DKnudsen[ispec]
        du[ispec] = u[ispec, 1] - u[ispec, 2]
        au[ispec] = 0.5 * (u[ispec, 1] + u[ispec, 2])
    end

    for ispec = 1:nspec(data)
        for jspec = 1:nspec(data)
            if ispec != jspec
                M[ispec, ispec] += au[jspec] / data.DBinary[ispec, jspec]
                M[ispec, jspec] = -au[jspec] / data.DBinary[ispec, jspec]
            end
        end
    end

    if VERSION >= v"1.9-rc0"
        ## Pivoting linear system solution via RecursiveFactorizations.jl
        @gc_preserve inplace_linsolve!(M, du, ipiv)
    else
        ## Non-pivoting implementation currently implemented in vfvm_functions.jl
        @gc_preserve inplace_linsolve!(M, du)
    end

    for ispec = 1:nspec(data)
        f[ispec] = du[ispec]
    end
end


function flux_marray(f, u, edge, data)
    T = eltype(u)
    n=nspec(data)

    M=MMatrix{nspec(data),nspec(data),T}(undef)
    au=MVector{nspec(data),T}(undef)
    du=MVector{nspec(data),T}(undef)
    ipiv=MVector{nspec(data),Int}(undef)

    
    for ispec = 1:nspec(data)
        M[ispec, ispec] = 1.0 / data.DKnudsen[ispec]
        du[ispec] = u[ispec, 1] - u[ispec, 2]
        au[ispec] = 0.5 * (u[ispec, 1] + u[ispec, 2])
    end

    for ispec = 1:nspec(data)
        for jspec = 1:nspec(data)
            if ispec != jspec
                M[ispec, ispec] += au[jspec] / data.DBinary[ispec, jspec]
                M[ispec, jspec] = -au[jspec] / data.DBinary[ispec, jspec]
            end
        end
    end

    ## Here, we also could use @gc_preserve.
    ## As this function is inlined one can avoid StrideArrays.jl
    ## Starting with Julia 1.8 one also can use callsite @inline.
    inplace_linsolve!(M,du)

    for ispec = 1:nspec(data)
        f[ispec] = du[ispec]
    end
end


function bcondition(f, u, node, data)
    for species = 1:nspec(data)
        boundary_dirichlet!(f, u, node; species, region = data.diribc[1],
                            value = species % 2)
        boundary_dirichlet!(f, u, node; species, region = data.diribc[2],
                            value = 1 - species % 2)
    end
end

function main(; n = 10, nspec = 5,
              dim = 2,
              Plotter = nothing,
              verbose = false,
              unknown_storage = :dense,
              flux=:flux_strided)
    
    h = 1.0 / convert(Float64, n)
    X = collect(0.0:h:1.0)
    DBinary = Symmetric(fill(0.1, nspec, nspec))
    for ispec = 1:nspec
        DBinary[ispec, ispec] = 0
    end

    DKnudsen = ones(nspec)

    if dim == 1
        grid = VoronoiFVM.Grid(X)
        diribc = [1, 2]
    elseif dim == 2
        grid = VoronoiFVM.Grid(X, X)
        diribc = [4, 2]
    else
        grid = VoronoiFVM.Grid(X, X, X)
        diribc = [4, 2]
    end

    function storage(f, u, node, data)
        f .= u
    end

    _flux= flux==:flux_strided ? flux_strided : flux_marray
    
    data = MyData{nspec}(DBinary, DKnudsen, diribc)
    sys = VoronoiFVM.System(grid; flux=_flux, storage, bcondition, species = 1:nspec, data)
    @time  u = solve(sys;
                     method_linear = KrylovJL_BICGSTAB(),
                     precon_linear = A -> factorize(A, UMFPACKFactorization())
                     )
    norm(u)
end

function test()
    main(; dim = 1) ≈ 5.193296208697211 &&
        main(; dim = 2) ≈ 17.224214949423878 &&
        main(; dim = 3) ≈ 57.1262582956693 &&
        main(; dim = 1, flux=:flux_marray) ≈ 5.193296208697211 &&
        main(; dim = 2, flux=:flux_marray) ≈ 17.224214949423878 &&
        main(; dim = 3, flux=:flux_marray) ≈ 57.1262582956693
    
    
end
end

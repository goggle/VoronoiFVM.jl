#=
 # 121: 1D Poisson with point charge
 ([source code](SOURCE_URL))

Solve a Poisson equation
```math
- \Delta u = 0
```

in $\Omega=(-1,1)$
with a point charge $Q$ at $x=0$. 
=#

module Example121_PoissonPointCharge1D

using Printf

using VoronoiFVM
using ExtendableGrids
using GridVisualize

function main(; nref = 0, Plotter = nothing, verbose = false, unknown_storage = :sparse,
              brea = false)

    ## Create grid in (-1,1) refined around 0
    hmax = 0.2 / 2.0^nref
    hmin = 0.05 / 2.0^nref
    X1 = geomspace(-1.0, 0.0, hmax, hmin)
    X2 = geomspace(0.0, 1.0, hmin, hmax)
    X = glue(X1, X2)
    grid = VoronoiFVM.Grid(X)

    ## Edit default region numbers:
    ##   additional boundary region 3 at 0.0
    bfacemask!(grid, [0.0], [0.0], 3)
    ## Material 1 left of 0
    cellmask!(grid, [-1.0], [0.0], 1)
    ## Material 2 right of 0
    cellmask!(grid, [0.0], [1.0], 2)

    Q::Float64 = 0.0

    function flux!(f, u, edge)
        f[1] = u[1, 1] - u[1, 2]
    end
    function storage!(f, u, node)
        f[1] = u[1]
    end

    ## Define boundary reaction defining charge
    ## Note that the term  is written on  the left hand side, therefore the - sign
    function breaction!(f, u, node)
        if node.region == 3
            f[1] = -Q
        end
    end

    ## Create physics
    physics = VoronoiFVM.Physics(; flux = flux!,
                                 storage = storage!,
                                 breaction = breaction!)

    ## Create system
    sys = VoronoiFVM.System(grid, physics; unknown_storage = :dense)

    ##  put potential into both regions
    enable_species!(sys, 1, [1, 2])

    ## Set boundary conditions

    boundary_dirichlet!(sys, 1, 1, 1.0)
    boundary_dirichlet!(sys, 1, 2, 0.0)

    ## Create a solution array
    U = unknowns(sys)
    U .= 0

    ## Create solver control info
    control = VoronoiFVM.NewtonControl()
    control.verbose = verbose

    vis = GridVisualizer(; Plotter = Plotter)
    ## Solve and plot for several values of charge
    for q in [0.1, 0.2, 0.4, 0.8, 1.6]
        if brea
            ## Charge in reaction term
            Q = q
        else
            ## Charge as boundary condition
            sys.boundary_values[1, 3] = q
        end
        U = solve(sys; inival = U, control)

        ## Plot data

        scalarplot!(vis, grid, U[1, :]; title = @sprintf("Q=%.2f", q), clear = true,
                    show = true)
    end
    return sum(U)
end

function test()
    main() ≈ 20.254591679579015
end
end

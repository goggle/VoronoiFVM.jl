# # 205: 2D Nonlinear Poisson equation
# ([source code](SOURCE_URL))

module Example205_NonlinearPoisson2D

using Printf
using VoronoiFVM
using ExtendableGrids
using ExtendableSparse
using GridVisualize
using LinearSolve
using ILUZero

function main(; n = 10, Plotter = nothing, verbose = false, unknown_storage = :sparse,
              max_lureuse = 0, method_linear = nothing,
              precon_linear = A -> LinearSolve.Identity())
    h = 1.0 / convert(Float64, n)
    X = collect(0.0:h:1.0)
    Y = collect(0.0:h:1.0)

    grid = VoronoiFVM.Grid(X, Y)

    eps = 1.0e-2

    physics = VoronoiFVM.Physics(; reaction = function (f, u, node)
                                     f[1] = u[1]^2
                                 end, flux = function (f, u, edge)
                                     f[1] = eps * (u[1, 1]^2 - u[1, 2]^2)
                                 end, source = function (f, node)
                                     x1 = node[1] - 0.5
                                     x2 = node[2] - 0.5
                                     f[1] = exp(-20.0 * (x1^2 + x2^2))
                                 end, storage = function (f, u, node)
                                     f[1] = u[1]
                                 end)
    sys = VoronoiFVM.System(grid, physics; unknown_storage = unknown_storage)
    enable_species!(sys, 1, [1])

    boundary_dirichlet!(sys, 1, 2, 0.1)
    boundary_dirichlet!(sys, 1, 4, 0.1)

    inival = unknowns(sys)
    inival .= 0.5

    control = VoronoiFVM.NewtonControl()
    control.verbose = verbose
    control.reltol_linear = 1.0e-5
    control.max_lureuse = max_lureuse
    control.method_linear = method_linear
    control.precon_linear = precon_linear
    tstep = 0.01
    time = 0.0
    u15 = 0
    p = GridVisualizer(; Plotter = Plotter)
    while time < 1.0
        time = time + tstep
        U = solve(sys; inival, control, tstep)
        u15 = U[15]
        inival .= U

        if verbose
            @printf("time=%g\n", time)
        end

        scalarplot!(p[1, 1], grid, U[1, :]; Plotter = Plotter, clear = true, show = true)
        tstep *= 1.0
    end
    return u15
end

function test()
    # test at once for iterative solution here
    testval = 0.3554284760906605
    main(; unknown_storage = :sparse, max_lureuse = 0) ≈ testval &&
        main(; unknown_storage = :dense, max_lureuse = 0) ≈ testval &&
        main(; unknown_storage = :sparse, max_lureuse = 10) ≈ testval &&
        main(; unknown_storage = :dense, max_lureuse = 10) ≈ testval &&
        main(; unknown_storage = :sparse, max_lureuse = 0,
             method_linear = KrylovJL_CG(), precon_linear = ILUZeroPreconditioner) ≈
        testval &&
        main(; unknown_storage = :dense, max_lureuse = 0,
             method_linear = KrylovJL_CG(), precon_linear = ILUZeroPreconditioner) ≈ testval
end
end

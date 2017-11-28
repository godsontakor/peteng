using JFVM
import PyPlot, JSON

include("../functions/rel_perms_real.jl")

function polymer_viscosity(cs, cp)
    a1 = 4.0
    a2 = 0.0
    a3 = 6.0
    sp = -0.24
    μ_w = 0.001 # Pa.s
    return μ_w*(1.0+cp.*cs.^sp.*(a1+a2*cp+a3*cp.*cp))
end

function dpolymer_viscosity_dcs(cs, cp)
    a1 = 4.0
    a2 = 0.0
    a3 = 6.0
    sp = -0.24
    μ_w = 0.001 # Pa.s
    return sp*μ_w*cp.*cs.^(sp-1).*(a1+a2*cp+a3*cp.*cp)
end

function dpolymer_viscosity_dcp(cs, cp)
    a1 = 4.0
    a2 = 0.0
    a3 = 6.0
    sp = -0.24
    μ_w = 0.001 # Pa.s
    return μ_w*cs.^sp.*(a1+2*a2*cp+3*a3*cp.*cp)
end

# domain
Lx = 1.0
Ly = 1.0
Nx = 100
Ny = 10
m = createMesh1D(Nx, Lx)

# (petro)physical properties
mu_oil = 10e-3 # Pa.s
perm = 0.1e-12
poros = 0.3

# rel-perms
krw0 = 0.2
kro0 = 0.8
n_o  = 2.0
n_w  = 2.0
swc  = 0.08
sor = 0.2

KRW  = sw -> krw.(sw, krw0, sor, swc, n_w)
dKRW = sw -> dkrwdsw.(sw, krw0, sor, swc, n_w)
KRO  = sw -> kro.(sw, kro0, sor, swc, n_o)
dKRO = sw -> dkrodsw.(sw, kro0, sor, swc, n_o)

# initial and boundary conditions
p_res = 100e5 # Pa reservoir (and right boundary pressure)
sw_0 = swc # inital water saturation
sw_inj = 1.0 # injection water saturation
cp_0 = 0.0 # initial polymer concentration kg/m^3
cp_inj = 1.0 # injected polymer concentration
cs_0 = 10.0  # initial salt concentration kg/m^3
cs_inj = 5.0 # injected salt concentration


φ = createCellVariable(m, poros) # porosity
k = createCellVariable(m, perm) # m^2 permeability
k_face   = harmonicMean(k) # harmonic averaging for perm
u_inj = 1e-5 # m/s injection Darcy velocity
pv_inj = 0.3 # injected pore volumes
t_final = pv_inj*Lx/(u_inj/poros) # s final time
dt0 = t_final/Nx # s time step
dt  = t_final/Nx # variable time step

BCp = createBC(m)   # pressure boundary
BCp.left.a[:] = perm/polymer_viscosity(cs_inj, cp_inj)
BCp.left.b[:] = 0.0
BCp.left.c[:] = -u_inj
BCp.right.a[:] = 0.0
BCp.right.b[:] = 1.0
BCp.right.c[:] = p_res
M_bc_p, RHS_bc_p = boundaryConditionTerm(BCp)

# saturation boundary
BCs = createBC(m)
BCs.left.a[:] = 0.0
BCs.left.b[:] = 1.0
BCs.left.c[:] = sw_inj # injected water saturation
M_bc_s, RHS_bc_s = boundaryConditionTerm(BCs)

# salt concentration boundary
BCcs = createBC(m)
BCcs.left.a[:] = 0.0
BCcs.left.b[:] = 1.0
BCcs.left.c[:] = cs_inj # injected salt concentration
M_bc_cs, RHS_bc_cs = boundaryConditionTerm(BCcs)

# polymer concentration boundary
BCcp = createBC(m)
BCcp.left.a[:] = 0.0
BCcp.left.b[:] = 1.0
BCcp.left.c[:] = cp_inj # injected polymer concentration
M_bc_cp, RHS_bc_cp = boundaryConditionTerm(BCcp)

# initial conditions
p_init  = createCellVariable(m, p_res)
sw_init = createCellVariable(m, sw_0)
cs_init = createCellVariable(m, cs_0)
cp_init = createCellVariable(m, cp_0)
p_val  = createCellVariable(m, p_res)
sw_val = createCellVariable(m, sw_0)
cs_val = createCellVariable(m, cs_0)
cp_val = createCellVariable(m, cp_0)

uw       = -gradientTerm(p_val)
# M_bc_p, RHS_bc_p = boundaryConditionTerm(BCp)
# M_bc_s, RHS_bc_s = boundaryConditionTerm(BCs)
# M_bc_c, RHS_bc_c = boundaryConditionTerm(BCcs)
# M_bc_t, RHS_bc_t = boundaryConditionTerm(BCt)
tol_s = 1e-7
tol_c = 1e-7
max_int_loop = 40
t = 0.0
FL = fluxLimiter("SUPERBEE") # flux limiter

while t<t_final
    error_s = 2*tol_s
    error_c = 2*tol_c
    loop_countor = 0
    while error_s>tol_s
        loop_countor += 1
        if loop_countor > max_int_loop
        sw_val = copyCell(sw_init)
        cp_val  = copyCell(cp_init)
        cs_val  = copyCell(cs_init)
        p_val  = copyCell(p_init)
        dt = dt/3.0
        break
        end
        ∇p0      = gradientTerm(p_val)
        ∇s0      = gradientTerm(sw_val)

        cs_face   = upwindMean(cs_val, uw)
        cp_face   = upwindMean(cp_val, uw)
        sw_face       = upwindMean(sw_val, uw)

        mu_water_face = faceEval(polymer_viscosity, cs_face, cp_face)
        d_mu_cs_face = faceEval(dpolymer_viscosity_dcs, cs_face, cp_face)
        d_mu_cp_face = faceEval(dpolymer_viscosity_dcp, cs_face, cp_face)
        d_cs_mu_dcs = (mu_water_face-d_mu_cs_face.*cs_face)./(mu_water_face.*mu_water_face)
        d_cs_mu_dcp = (-d_mu_cp_face.*cs_face)./(mu_water_face.*mu_water_face)
        d_cp_mu_dcp = (mu_water_face-d_mu_cp_face.*cp_face)./(mu_water_face.*mu_water_face)
        d_cp_mu_dcs = (-d_mu_cs_face.*cp_face)./(mu_water_face.*mu_water_face)
        d_mu_dcs = -d_mu_cs_face./(mu_water_face.*mu_water_face)
        d_mu_dcp = -d_mu_cp_face./(mu_water_face.*mu_water_face)

        # println("visc")
        krw_face      = faceEval(KRW,sw_face)
        kro_face      = faceEval(KRO,sw_face)

        λ_w_face      = k_face.*krw_face./mu_water_face
        λ_o_face      = k_face.*kro_face/mu_oil
        uw            = -λ_w_face.*∇p0
        uo            = -λ_o_face.*∇p0
        ut            = uw + uo

        dλ_w_face     = k_face.*faceEval(dKRW,sw_face)./mu_water_face
        dλ_o_face     = k_face.*faceEval(dKRO,sw_face)./mu_oil

        # water mass balance (wmb)
        M_t_s_wmb, RHS_t_s_wmb = transientTerm(sw_init, dt, φ)
        M_d_p_wmb = diffusionTerm(-λ_w_face)
        M_a_s_wmb = convectionUpwindTerm(-dλ_w_face.*∇p0, ut)
        M_a_cs_wmb, RHS_a_cs_wmb = convectionTvdTerm(-k_face.*d_mu_dcs.*∇p0, cs_val, FL, ut)
        M_a_cp_wmb, RHS_a_cp_wmb = convectionTvdTerm(-k_face.*d_mu_dcp.*∇p0, cp_val, FL, ut)

        # oil mass balance (omb)
        M_t_s_omb, RHS_t_s_omb = transientTerm(sw_init, dt, -φ)
        M_d_p_omb = diffusionTerm(-λ_o_face)
        M_a_s_omb = convectionUpwindTerm(-(dλ_o_face.*∇p0), ut)

        # salt mass balance
        M_t_cs_smb, RHS_t_cs_smb = transientTerm(cs_init, dt, sw_val.*φ)
        # M_a_cs_smb, RHS_a_cs_smb = convectionTvdTerm(uw, cs_val, FL, ut)
        M_a_s_smb = convectionUpwindTerm(-dλ_w_face.*cs_face.*∇p0, ut)        
        M_d_p_smb = diffusionTerm(-λ_w_face.*cs_face)
        M_a_cs_smb, RHS_a_cs_smb = convectionTvdTerm(-k_face.*d_cs_mu_dcs.*∇p0, cs_val, FL, ut)
        M_a_cp_smb, RHS_a_cp_smb = convectionTvdTerm(-k_face.*d_cs_mu_dcp.*∇p0, cp_val, FL, ut)

        # polymer mass balance
        M_t_cp_pmb, RHS_t_cp_pmb = transientTerm(cp_init, dt, sw_val.*φ)
        M_a_s_pmb = convectionUpwindTerm(-dλ_w_face.*cp_face.*∇p0, ut)        
        # M_a_cp, RHS_a_cp = convectionTvdTerm(uw, cp_val, FL, ut)
        M_d_p_pmb = diffusionTerm(-λ_w_face.*cp_face)
        M_a_cs_pmb, RHS_a_cs_pmb = convectionTvdTerm(-k_face.*d_cp_mu_dcs.*∇p0, cs_val, FL, ut)
        M_a_cp_pmb, RHS_a_cp_pmb = convectionTvdTerm(-k_face.*d_cp_mu_dcp.*∇p0, cp_val, FL, ut)

        # create the PDE system M [p;s;c]=RHS
        # x_val = [p_val.value[:]; sw_val.value[:]; c_val.value[:]]
        M = [M_bc_p+M_d_p_wmb   M_t_s_wmb+M_a_s_wmb  M_a_cs_wmb  M_a_cp_wmb;
            M_d_p_omb   M_bc_s+M_t_s_omb+M_a_s_omb  zeros(Nx+2,Nx+2)  zeros(Nx+2,Nx+2);
            M_d_p_smb  M_a_s_smb  M_a_cs_smb+M_t_cs_smb+M_bc_cs  M_a_cp_smb;
            M_d_p_pmb  M_a_s_pmb  M_a_cs_pmb  M_t_cp_pmb+M_bc_cp+M_a_cp_pmb] 

        RHS = [RHS_bc_p+RHS_t_s_wmb+M_a_s_wmb*sw_val.value[:]+RHS_a_cs_wmb+RHS_a_cp_wmb+M_a_cs_wmb*cs_val.value[:]+M_a_cp_wmb*cp_val.value[:];
               RHS_bc_s+RHS_t_s_omb+(M_a_s_omb)*sw_val.value[:];
               RHS_t_cs_smb+RHS_a_cs_smb+RHS_a_cp_smb+RHS_bc_cs+M_a_s_smb*sw_val.value[:]+M_a_cs_smb*cs_val.value[:]+M_a_cp_smb*cp_val.value[:];
               RHS_t_cp_pmb+RHS_a_cs_pmb+RHS_a_cp_pmb+RHS_bc_cp+M_a_s_pmb*sw_val.value[:]+M_a_cs_pmb*cs_val.value[:]+M_a_cp_pmb*cp_val.value[:]]

        # x_sol = solveLinearPDE(m, M, RHS)
        x_sol = M\RHS

        p_new = x_sol[1:Nx+2]
        s_new = x_sol[(1:Nx+2)+(Nx+2)]
        cs_new = x_sol[(1:Nx+2)+2*(Nx+2)]
        cp_new = x_sol[(1:Nx+2)+3*(Nx+2)]

        error_s = sum(abs, s_new[2:end-1]-internalCells(sw_val))
        

        #   error_c = sum(abs, internalCells(cp_val)-internalCells(cp_val))
        # println(error_s)
        # println(error_c)
        # w_p = 0.9
        # w_sw = 0.8
        # w_c = 0.8
        # p_val.value[:] = w_p*p_new[:]+(1-w_p)*p_val.value[:]
        # sw_val.value[:] = w_sw*s_new[:]+(1-w_sw)*sw_val.value[:]
        # c_val.value[:] = w_c*c_new[:]+(1-w_c)*c_val.value[:]
        p_val.value[:] = p_new[:]
        dsw_apple = 0.2
        eps_apple = sqrt(eps()) # 1e-5
        for i in eachindex(s_new)
            if s_new[i]>=(1-sor)
                if sw_val.value[i]<(1-sor-eps_apple)
                    sw_val.value[i] = 1-sor-eps_apple
                else
                    sw_val.value[i] = 1-sor
                end
            elseif s_new[i]<=swc
                if sw_val.value[i]> swc+eps_apple
                    sw_val.value[i] = swc+eps_apple
                else
                    sw_val.value[i] = swc
                end
            elseif abs(s_new[i]-sw_val.value[i])>dsw_apple
                sw_val.value[i] += dsw_apple*sign(s_new[i]-sw_val.value[i])
            else
                sw_val.value[i] = s_new[i]
            end
        end
        sw_val = createCellVariable(m, internalCells(sw_val), BCs)
        cs_new[2:end-1][cs_new[2:end-1].<0.0] = 0.0
        cp_new[2:end-1][cp_new[2:end-1].<0.0] = 0.0
        
        cs_val.value[:] = cs_new[:]
        cp_val.value[:] = cp_new[:]

        # GR.plot(sw_val.value)
        # sw_val.value[:] = w_sw*s_new[:]+(1-w_sw)*sw_val.value[:]
    end
    if loop_countor<max_int_loop
        p_init = copyCell(p_val)
        sw_init = copyCell(sw_val)
        cp_init = copyCell(cp_val)
        cs_init = copyCell(cs_val)
        
        t +=dt
        dt = dt0
        println("progress: $(t/(t_final)*100) [%]")
    end
  end
  # JLD.save("results2D/all_data_heterogen_wf.jld", "p", p_val, "c", c_val,
  # "c_oil", c_oil, "sw", sw_val, "c_tracer", c_t_val)
  # figure(1)
  figure()
  visualizeCells(sw_init)
  # title("Sw")
  figure()
  visualizeCells(cs_init)
  # title("c_DME")
  figure()
  visualizeCells(cp_init)
  # title("c_tracer")
  # savefig("profile.png")
  # figure(2)
  # plot(t_s, rec_fact)
  # savefig("recovery.png")
  # figure(3)
  # plot(t_s, dp_hist)
  # savefig("dp.png")
  # PyPlot.pcolormesh(sw_val.value[2:end-1, 2:end-1]', cmap="YlGnBu", shading = "gouraud", vmin=0, vmax=1)

  
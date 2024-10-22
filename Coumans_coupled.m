function [u, phi, rho, drhodt, melt_visc, eta, P, H2O, xH2O, R, Nb, T, ...
         Cc, pb, m_loss, zz_p, zz_u, zz_t, t,...
         hoop_stress, along_strain_rate, transverse_strain_rate, bubble_strain_rate] = Coumans_coupled(Composition, H2Ot_0, Geometry, radius, z_int0, ...
    BC, BC_type, BC_T, flux, SolModel, DiffModel, ViscModel, EOSModel, rhoModel,  PermModel, OutgasModel, ...
    SurfTens, melt_rho,...
    rock_rho, env_rho, alpha, melt_beta, etar, Nb_0, R_0, phi_0,...
    P_0, P_f, dPdt, T_0, T_f, PTtModel, Buoyancy, dTdt, t_quench, tf,...
    solve_T, t_min, t_max, nt, n_magma)

%Gets the matlab filename
mfilename;
%Gets the folder (local computer) where the script is saved
mpath = strrep(which(mfilename),[mfilename '.m'],'');
mFolder = mpath;
%Adds the folder to the path so that local functions can be called
addpath(mFolder)

warning('off','MATLAB:illConditionedMatrix')
warning('off','MATLAB:nearlySingularMatrix')


[SolFun, DiffFun, ViscFun, m0_fun, pb_fun,...
    PTt_fun_set] = getFunctions_v2(SolModel,DiffModel, ViscModel,...
    EOSModel, PTtModel);
[SolFun, DiffFun, ViscFun, m0_fun, pb_fun,...
    PTt_fun] = getFunctions_v2(SolModel,DiffModel, ViscModel,...
    EOSModel, 'Evolving');
[DynFun] = getFunctions_dynamic_dimensionless(Geometry,BC);
[DarcyFun,PermFun,WaterViscModel,...
    OutgasFun] = getFunctions_outgas(Geometry,PermModel,OutgasModel);

if solve_T
[ThermFun,cpmeltFun,cpFun,kmeltFun,kFun,...
    rhoFun] = getFunctions_thermal(Geometry,BC_type,...
    'BagdassarovDingwell1994','Bruggeman',rhoModel,alpha,T_0);
kmelt = kmeltFun(Composition);
end

%Finite difference parameters
Nodes = 50; %Number of nodes in spatial discretization

%Numerical tolerance:
%[Absolute tolerance, relative tolerance], see:
Numerical_Tolerance = [1e-5, 1e-5];
eta_max = 1e12;
Tgfun = @(T) ViscFun(H2Ot_0,T,Composition) - 1e12;
Tg = fzero(Tgfun,600+273);

%Time discretization
t = zeros([1,nt]);
dt = t_min*10; 
t(2) = dt;

% Spatial discretization
switch Geometry
    case 'Radial'
        z_t = radius*(1-logspace(0,-1,2*n_magma+1))*(1/(1-1e-1));
        z_u = z_t(1:2:end);
        z_p = z_t(2:2:end);
        g = 0;
        
    case 'Cylindrical'
        z_t = z_int0*(1-logspace(0,-1,2*n_magma+1))*(1/(1-1e-1)); 
        z_u = z_t(1:2:end);
        z_p = z_t(2:2:end);
        g = 0;%9.81;
end

% Intialize variables
[zz_t,tt_t] = meshgrid(z_t,t);
[zz_p,tt_p] = meshgrid(z_p,t);
[zz_u,tt_u] = meshgrid(z_u,t);

u = zeros(size(tt_u));
phi = ones(size(tt_p));
rho = zeros(size(tt_t));
drhodt = zeros(size(tt_p));
melt_visc = zeros(size(tt_t));
eta = zeros(size(tt_p));
beta = zeros(size(tt_p));
dbetadt = zeros(size(tt_p));
P = zeros(size(tt_p));
H2O = zeros([size(tt_p),Nodes]);
xH2O = zeros([size(tt_p),Nodes]);
R = zeros(size(tt_p));
Nb = zeros(size(tt_p));
T = zeros(size(tt_t));
Cc = zeros(size(tt_p));
pb = zeros(size(tt_p));
m_loss = zeros(size(tt_p));
mean_H2O =  zeros(size(tt_t));
hoop_stress = zeros(size(tt_p));
along_strain_rate = zeros(size(tt_u));
transverse_strain_rate = zeros(size(tt_u));
bubble_strain_rate = zeros(size(tt_p));

u_t = z_t;
u_interp = 0*z_p;

W = Mass_SingleOxygen(Composition);
pp = 2.3e3;

% Model tolerances
erri = 5e-4;
tol = erri;
mm = 0;
w = 0.6;

% Plot options
cmap = hot(2*length(t));

if tf>5*24*60*60
    t_unit = 'days';
elseif tf>5*60*60
    t_unit = 'hr';
elseif tf>5*60
    t_unit = 'min';
else
    t_unit = 's';
end

if contains(t_unit,'s')
    t_stretch = 1;
elseif contains(t_unit,'min')
    t_stretch = 60;
elseif contains(t_unit,'hr')
    t_stretch = 60*60;
elseif contains(t_unit,'days')
    t_stretch = 60*60*24;
end

% Initialize plots
f3 = figure(3); clf;
switch Geometry
    case 'Radial'
        f3.Position = [400,100,600,700];
    case 'Cylindrical'
        f3.Position = [400,100,1200,700];
end
set(gcf,'color','w');

labels = {'Pressure (Pa)','Velocity (m/s)','Mean H2O (wt %)','\phi','Temperature (^oC)'};

switch Geometry
    case 'Radial'
        ax3 = create_axes(5,'vertical');
    case 'Cylindrical'
        ax3 = create_axes(5,'horizontal');
end

linewidth = 2;

% Initial conditions
i = 1;

while t(max([1,i-1]))<tf && i<=nt
    % Step 1
    if i == 1
        phi_interp = phi_0;
        if solve_T       
            rho(i,:) = rhoFun(melt_rho,T_0 + T(1,:)).*(1-phi_interp) + density(P_0+(2.*(SurfTens)./R_0),T_0,coefficients()).*phi_interp;
        else
            rho(i,:) = melt_rho * (1-phi_interp)  + density(P_0+(2.*(SurfTens)./R_0),T_0,coefficients())*phi_interp;
        end
        
        dz = [(zz_p(1,2:end)-zz_p(1,1:end-1)),zz_p(1,end)-zz_p(1,end-1)];
        switch Geometry
            case 'Radial'
                P(i,:) = P_0;
                Plith = P_0*ones(size(P(i,:)));
            case 'Cylindrical'

                switch Buoyancy
                    case 'True'
                        P(i,:) = cumsum(rho(i,2:2:end).*dz*g,'reverse')-rho(i,end).*dz(end)/2*g + P_0;
                        Plith = cumsum(rock_rho(i,2:2:end).*dz*g,'reverse')-rock_rho(i,end).*dz(end)/2*g + P_0;
                    case 'False'
                        P(i,:) = cumsum(rho(i,2:2:end).*dz*g,'reverse')-rho(i,end).*dz(end)/2*g + P_0;
                        Plith = cumsum(rho(i,2:2:end).*dz*g,'reverse')-rho(i,end).*dz(end)/2*g + P_0;
                end
        end
        T(i,:) = T_0;

        R(i,:) = R_0;
        Nb(i,:) = Nb_0;
        phi(i,:) = phi_0;
        pb(i,:) = P(i,:)+(2.*(SurfTens)./R(i,:));
        m_loss(i,:) = m0_fun(R_0, pb(i,1), T(i,1));

        H2O(i,:,:) = H2Ot_0;
        mean_H2O(i,:) = H2Ot_0;
        
        L = R_0*(phi_0^(-1/3) - 1); 
        xB=[0 logspace(-2,0,Nodes)*L]' + R_0;
        xH2O(i,:,:) = repmat((xB(2:end,1)+xB(1:end-1,1))/2,[1,length(z_p)])';

        melt_visc(i,:) = min(eta_max,ViscFun(H2Ot_0,T(i,:)',Composition));
        melt_visc(i,T(i)<=500) = eta_max./etar;
        %melt_visc(i,end-1:end) = max(1,1e-4*min(melt_visc(i,1:end-2)));
        eta(i,:) =  melt_visc(i,2:2:end).*etar;
        beta(i,:) = phi(i,:)./P(i,:) + (1-phi(i,:)).*melt_beta;
        dudr = 0;
        dudr_prev = 0;
        dudr_prev2 = 0;

    else 

        % Adaptive time stepping
        u_t(1:2:end) = u(i-1,:);
        u_t(2:2:end) = u_interp;
        dt_stable = min(abs(1/2*(zz_t(i-1,2:end)-zz_t(i-1,1:end-1))./(u_t(2:end)-u_t(1:end-1))));
        if dt_stable == 0
            break
        end

        if i>3
            dt = dt*max(min(1.05,mean([(t(i-1)-t(i-2))/(t(i-2)-t(i-3)); (norm(u(i-2,:))/norm(u(i-1,:)))])),0.95);
        end

        u_t(1:2:end) = u(i-1,:);
        u_t(2:2:end) = u_interp;
        dt_stable = max([t_max,-min([0,min(1/2*(zz_t(i-1,2:end)-zz_t(i-1,1:end-1))./(u_t(2:end)-u_t(1:end-1)))])]);

        dt = min([t_max,max([t_min,dt]),dt_stable])

        if any(P(i-1,:) < 0) | any(pb(i-1,:)<0) | any(isnan(P(i-1,:))) | any(abs(P(max(i-2,1),:)./P(i-1,:))>100)
            i = i-2
            if i>2
                dt = (t(i-1) - t(i-2))*0.8
            else
                i = 2
                dt = (t(2) - t(1))*0.8
            end
            'Low pressure'
        end

        if any((zz_t(i-1,2:end) - zz_t(i-1,1:end-1))<0)
            i = i-2
            if i>2
                dt = (t(i-1) - t(i-2))*0.8
            else
                i = 2
                dt = (t(2) - t(1))*0.8
            end
            'Time step too large'
            break 
        end

        if mm>5
            i = i-2

            if i>2
                dt = (t(i-1) - t(i-2))*0.8
            else
                i = 2
                dt = (t(2) - t(1))*0.8
            end
            'Failed to converge'
            break
        end

        t(i) = t(i-1) + dt;
        if i>2
            %[~,~,~,Bt,~,Dt,~,Ft] = FDcoeff(t(i-2:i));
            dt2 = t(i-1) - t(i-2);
            Bt = (dt + dt2)/dt/dt2;
            Dt = dt/dt2/(dt+dt2);
            Ft = (dt2+2*dt)/dt/(dt2+dt);

        else
            Dt = [0,0];
            Bt = [-1/dt,-1/dt];
            Ft = [1/dt, 1/dt];
        end

        % Main loop
        n = 0;
        m = 0;
        mm = 0;
        while ((erri>tol) || (n==0) || (m<3)) && (mm<5);
            % reset if stability not met
            if m>30
                dt = 0.8*dt
                n = 0; 
                m = 0; 
                t(i) = t(i-1) + dt;
                mm = mm + 1;
                if i>2
                    %[~,~,~,Bt,~,Dt,~,Ft] = FDcoeff(t(i-2:i));
                    dt2 = t(i-1) - t(i-2);
                    Bt = (dt + dt2)/dt/dt2;
                    Dt = dt/dt2/(dt+dt2);
                    Ft = (dt2+2*dt)/dt/(dt2+dt);
                    else
                    Dt = [0,0];
                    Bt = [-1/dt,-1/dt];
                    Ft = [1/dt, 1/dt];
                end
            end

            u_t(1:2:end) = u(i-1+n,:);
            u_t(2:2:end) = u_interp;
            dt_stable = min(1/2*(zz_t(i-1,2:end)-zz_t(i-1,1:end-1))./(u_t(2:end)-u_t(1:end-1)));
            if dt_stable<0
                dt = min([dt,-dt_stable]);
                t(i) = t(i-1) + dt;
                if i>2
                    %[~,~,~,Bt,~,Dt,~,Ft] = FDcoeff(t(i-2:i));
                    dt2 = t(i-1) - t(i-2);
                    Bt = (dt + dt2)/dt/dt2;
                    Dt = dt/dt2/(dt+dt2);
                    Ft = (dt2+2*dt)/dt/(dt2+dt);
                else
                    Dt = [0,0];
                    Bt = [-1/dt,-1/dt];
                    Ft = [1/dt, 1/dt];
                end
            end            

            % Interpolation between grids
            phi_interp = griddedInterpolant(zz_p(i-1,:),phi(i-1+n,:),'linear','nearest');
            phi_interp = phi_interp(zz_t(i-1,:));
            phi_interp(phi_interp>0.999) = 0.999;
            pb_interp = griddedInterpolant(zz_p(i-1,:),pb(i-1+n,:),'linear','nearest');
            pb_interp = pb_interp(zz_t(i-1,:));

            if solve_T
                rho(i,:) = rhoFun(melt_rho,T(i-1+n,:)).*(1-phi_interp) + density(pb_interp,T(i-1+n,:)',coefficients()).*phi_interp;
                %rho(i,:) = melt_rho.*(1-phi_interp) + density(pb_interp,T(i-1+n,:)',coefficients()).*phi_interp;
            else
                rho(i,:) = melt_rho.*(1-phi_interp) + density(pb_interp,T(i-1+n,:)',coefficients()).*phi_interp;
            end
    
            if solve_T
                %H2O_interp = griddedInterpolant(zz_p(i-1,:),mean_H2O(i-1+n,:),'linear','nearest');
                %H2O_interp = H2O_interp(zz_t(i-1,:));
                cpmelt = cpmeltFun(Composition,T(i-1+n,:),mean_H2O(i-1+n,:));
                cp = cpFun(phi_interp,cpmelt,rhoFun(melt_rho,T(i-1+n,:)),T(i-1+n,:),pb_interp);
                k = kFun(phi_interp,kmelt);

                % Initial temperature solution
                PT = PTt_fun_set(P_0, P_f, dPdt,T_0,T_f,dTdt,t_quench,t(i));
  
                switch BC_type
                    case 'Forced'
                        BC_Ti = BC_T;
    
                    case 'Dirichlet'
                        BC_Ti = PT(2);
                end
   
                if i == 2
                    T(i,:) = ThermFun(T(i-1,:),T(i-1,:),rho(i,:),cp,k,zz_t(i-1,:),dt,dt,BC_Ti,flux,'BDF1');
                else
                    T(i,:) = ThermFun(T(i-1,:),T(i-2,:),rho(i,:),cp,k,zz_t(i-1,:),dt,t(i-1)-t(i-2),BC_Ti,flux,'BDF2');
                end
    
            else
                T(i,:) = PT(nt+i);
            end

            % Diffusive gas loss
            H2O(i,:,:) = H2O(i-1,:,:);
            mean_H2O(i,:) = mean_H2O(i-1,:);
            switch OutgasModel
                case 'Diffusive'
                    P_interp = griddedInterpolant(zz_p(i-1,:),P(i-1,:),'linear','nearest');
                    P_interp = P_interp(zz_t(i-1,:));
                    D = DiffFun(mean_H2O(i-1,:),T(i,:), P_interp, W);
                    mean_H2O_diff = OutgasFun(mean_H2O(i-1,:),mean_H2O(i-1,:),D,zz_t(i-1,:),dt,dt,SolFun(BC_T(end),pp),'BDF1');
                    mean_H2O(i,1:2:end) = mean_H2O_diff(1:2:end);
                    H2O(i,:,end) = mean_H2O_diff(2:2:end);                    
            end

            % Run Coumans 2020 for each pressure node
            for j = 1:length(z_p)

                % Skip nodes that can't grow
                if (R(i-1,j)<=1.01e-6 && SolFun(T(i-1,2*j),pb(i-1,j))>mean_H2O(i-1,2*j)) || T(i-1,2*j)<Tg
                    Nb(i,j) = Nb(i-1,j);
                    R(i,j) = R(i-1,j);
                    phi(i,j) = phi(i-1,j);
                    P(i,j) = P(i-1,j);
                    xH2O(i,j,:) = xH2O(i-1,j,:);
                    pb(i,j) = pb(i-1,j);
                    dPdti = 0;
                    Pi = 0;
                    m_loss(i,j) = m_loss(i-1,j);

                else         
                    % Project pressure and temperature
                    if i >2
                        dTdti = Dt*T(i-2,j) -Bt*T(i-1,j) + Ft*T(i,j);
                        if n == 0
                            if i>3
                                h1 = t(i-1) - t(i-2);
                                h2 = t(i-2) - t(i-3);
                                dPdti = (P(i-1,j)-P(i-2,j))./(t(i-1)-t(i-2)) + (h2.*P(i-3,j) - (h1 + h2).*P(i-2,j) + h1.*P(i-1,j))./(h1.*h2.*(h1 + h2))*dt;
                            else
                                dPdti = (P(i-1,j)-P(i-2,j))./(t(i-1)-t(i-2));
                            end
                            Pf = P(i-1,j) + dPdti*dt;
                        else
                            dPdti = Dt*P(i-2,j) -Bt*P(i-1,j) + Ft*P_temp(j);
                            Pf = P_temp(j);
                        end
                    else
                        dTdti = (T(i,j) - T(i-1,j))./dt;

                        if n == 0
                            dPdti = 0;
                            Pf = P(i-1,j);
                        else
                            dPdti = (P_temp(j) - P(i-1,j))./dt;
                            Pf = P_temp(j);
                        end
                    end

                    % Call Coumans 2020
                    [ti, Ri, phii, Pii, Tii, x_out, H2Ot_all, Nbi, pbi, mi] =  Numerical_Model_v2(Composition, SolModel, DiffModel,...
                        ViscModel, EOSModel,OutgasModel, 'Evolving', SurfTens, melt_rho, Nodes,...
                        R(i-1,j),...
                        [squeeze(H2O(1,j,:)),squeeze(H2O(i,j,:)), squeeze(xH2O(i-1,j,:))], m_loss(i-1,j),...
                        Nb(i-1,j), 0, dt, T(i-1,j), T(i,j), dTdti,...
                        P(i-1,j), Pf,...
                        dPdti, 1e10, Numerical_Tolerance,...
                        eta(i-1+n,:), zz_p(i-1,:), j, Geometry, radius);

                    % Update solution with SOR
                    Nb(i,j) = w*Nbi(end) + (1-w)*Nb(i-1+n,j);
                    R(i,j) = w*Ri(end) + (1-w)*R(i-1+n,j);
                    phi(i,j) = w*phii(end) + (1-w)*phi(i-1+n,j);
                    xH2O(i,j,:) = x_out(:,end);
                    H2O(i,j,:) = H2Ot_all(:,end);
                    mean_H2O(i,2*j) = trapz(x_out(:,end).^3,H2Ot_all(:,end))./(x_out(end,end).^3-x_out(1,end).^3);
                    pb(i,j) = w*pbi(end) + (1-w)*pb(i-1+n,j);
                    m_loss(i,j) = w*mi(end) + (1-w)*m_loss(i-1+n,j);
                end
            end

            H2O_diff = griddedInterpolant(zz_p(i-1,:),mean_H2O(i,2:2:end) - mean_H2O(i-1,2:2:end),'linear','nearest');
            H2O_diff = H2O_diff(zz_u(i-1,:));
            mean_H2O(i,1:2:end) = mean_H2O(i,1:2:end) + H2O_diff;
            
            % Interpolate between grids
            phi_interp = griddedInterpolant(zz_p(i-1,:),phi(i,:),'linear','nearest');
            phi_interp = phi_interp(zz_t(i-1,:));
            phi_interp(phi_interp>0.999) = 0.999;
            pb(i,pb(i,:)<1) = 1;
            pb_interp = griddedInterpolant(zz_p(i-1,:),pb(i,:),'linear','nearest');
            pb_interp = pb_interp(zz_t(i-1,:));
            
            gas_rho = density(pb_interp,T(i,:)',coefficients());
            if solve_T
                rho(i,:) = rhoFun(melt_rho,T(i,:)).*(1-phi_interp) + gas_rho.*(phi_interp);
            else
                rho(i,:) = melt_rho*(1-phi_interp) + gas_rho.*(phi_interp);
            end

            %H2O_interp = griddedInterpolant(zz_p(i-1,:),mean_H2O(i,:),'linear','nearest');
            %H2O_interp = H2O_interp(zz_t(i-1,:));

            melt_visc(i,:) = min(eta_max,ViscFun(mean_H2O(i,:)',T(i,:)',Composition));
            melt_visc(i,T(i,:)<=500) = eta_max./etar;
            beta(i,:) = phi(i,:)./pb(i,:) + (1-phi(i,:)).*melt_beta;

            if i == 2
                drhodt(i,:) = (rho(i,2:2:end) - rho(i-1,2:2:end))./dt;
                dbetadt(i,:) = (beta(i,:) - beta(i-1,:))./dt;
            else
                drhodt(i,:) = Dt*rho(i-2,2:2:end) - Bt*rho(i-1,2:2:end) + Ft*rho(i,2:2:end);
                dbetadt(i,:) = Dt*beta(i-2,:) - Bt*beta(i-1,:) + Ft*beta(i,:);
            end
            

            % Dynamics
    
            if i == 2 
                [Pi, ui] = DynFun(P(i-1,:)-mean(Plith),u(i-1,:), ...
                    P(i-1,:)-mean(Plith),u(i-1,:),Plith-mean(Plith), ...
                    rho(i,:),drhodt(i,:),phi(i,:),R(i,:),SurfTens,melt_visc(i,:).*etar, ...
                    beta(i,:),dbetadt(i,:),radius,g,zz_p(i-1,:),zz_u(i-1,:),dt,dt,'BDF1');
            else
                [Pi, ui] = DynFun(P(i-1,:)-mean(Plith),u(i-1,:), ...
                    P(i-2,:)-mean(Plith),u(i-2,:),Plith-mean(Plith), ...
                    rho(i,:),drhodt(i,:),phi(i,:),R(i,:),SurfTens,melt_visc(i,:).*etar, ...
                    beta(i,:),dbetadt(i,:),radius,g,zz_p(i-1,:),zz_u(i-1,:),dt,t(i-1)-t(i-2),'BDF2');
            end

            P_temp = ((P(i-1+n,:) + dt*dPdti) + (Pi + mean(Plith)))/2;
            P(i,:) = Pi + mean(Plith);
            erri = norm(u(i,:) - ui)./max(((norm(u(i,:)) + norm(u(i-1,:)))/2),1e-12);
            u(i,:) = ui;
            u_interp = interp1(zz_u(i-1,:),u(i,:),zz_p(i-1,:),'linear');
           
            % Calculate capillary number
            switch Geometry
                case 'Radial'
                    dudr = (u(i,2:end) - u(i,1:end-1))./(zz_u(i-1,2:end)-zz_u(i-1,1:end-1));
                case 'Cylindrical'
                    dudr = -3*u_interp/radius;
            end

            if i>2
                d2udrdt = (Ft.*dudr - Bt.*dudr_prev + Dt*dudr_prev2);
            else
                d2udrdt = 0;
            end

            Cc(i,:) = max(sqrt((d2udrdt./dudr).^2 + dudr.^2),1e-10).*R(i,:).*melt_visc(i,2:2:end).*etar/SurfTens;
            eta0 = (1-phi(i,:)).^(-1);
            etainf = (1-phi(i,:)).^(5/3);
            eta(i,:) = melt_visc(i,2:2:end).*etar.*(etainf + (eta0-etainf)./(1+(6/5*Cc(i,:)).^2));
            eta(eta>eta_max) = eta_max;

            % Permeable outgassing

            min_density = density(Plith(end),T(i,2:2:end)',coefficients()).*4/3.*pi().*R(i,:).^3;
            m_loss(i,:) = DarcyFun(pb_fun,m_loss(i,:),pb(i,:),Plith,radius,z_p,...
                PermFun(phi(i,:),Cc(i,:)),...
                WaterViscModel(gas_rho(2:2:end),T(i,2:2:end)),...
                gas_rho(2:2:end),Nb(i,:),R(i,:),T(i,2:2:end),dt,min_density);
            
            %m_loss(i,:) = max(min_density.*4/3.*pi().*R(i,:).^3,m_loss(i,:) + M*dt);
            pb(i,:) = pb_fun(m_loss(i,:), T(i,2:2:end), R(i,:));

            % calculate failure
            hoop_stress(i,:) = (P(i,:)-P_0).*(radius)./(2*((zz_u(i-1,end)-zz_p(i-1,:))));
            along_strain_rate(i,2:end) = (u(i,2:end) - u(i,1:end-1))./(zz_u(i-1,2:end)-zz_u(i-1,1:end-1)).*melt_visc(i,3:2:end)/1e10;
            switch Geometry
                case 'Radial'
                    transverse_strain_rate(i,2:end) = 1./zz_u(i-1,2:end).*u(i,2:end).*melt_visc(i,3:2:end)/1e10;
                case 'Cylindrical'
                    transverse_strain_rate(i,:) = dudr.*melt_visc(i,1:2:end)/1e10;
            end
            
            if i>2
                dRdt = (Ft.*R(i,:) - Bt.*R(i-1,:) + Dt*R(i-2,:));
            else
                dRdt = (R(i,:)-R(i-1,:))./dt;
            end
            bubble_strain_rate(i,:) = 1./xH2O(i,:,1).*(abs(dRdt)).*ViscFun(squeeze(H2O(i,:,1)),T(i,2:2:end),Composition)./1e10;

            % Update coordinates
            if i == 2
                zz_p(i,:) = zz_p(i-1,:)+u_interp.*dt;
                zz_u(i,:) = zz_u(i-1,:)+u(i,:).*dt;
    
                zz_t(i,1:2:end) = zz_t(i-1,1:2:end)+u(i,:).*dt;
                zz_t(i,2:2:end) = zz_t(i-1,2:2:end)+u_interp.*dt;
    
            else
                zz_p(i,:) = -Dt/Ft*zz_p(i-2,:) + Bt/Ft*zz_p(i-1,:) + 1/Ft.*u_interp;
                zz_u(i,:) = -Dt/Ft*zz_u(i-2,:) + Bt/Ft*zz_u(i-1,:) + 1/Ft.*u(i,:);
    
                zz_t(i,1:2:end) = -Dt/Ft*zz_t(i-2,1:2:end) + Bt/Ft*zz_t(i-1,1:2:end) + 1/Ft.*u(i,:);
                zz_t(i,2:2:end) = -Dt/Ft*zz_t(i-2,2:2:end) + Bt/Ft*zz_t(i-1,2:2:end) + 1/Ft.*u_interp;
            end
    
            switch Geometry
                case 'Radial'
                    radius = zz_t(i-1,end);
            end

            % Plot results
            figure(8);
            if m == 0
                clf;
            end
            subplot(5,2,1); hold on;
            plot(m,mean(P(i,:)),'o','MarkerFaceColor','k')
            ylabel('Pressure (Pa)')
            title(['i = ' string(i)])
            subplot(5,2,2); hold on;
            plot(m,mean(drhodt(i,:)),'o','MarkerFaceColor','k')
            title(['t = ' string(t(i))])
            ylabel('d\rho/dt (m/s)')
            subplot(5,2,3); hold on;
            plot(m,mean(phi_interp),'o','MarkerFaceColor','k')
            ylabel('Vesicularity')

            subplot(5,2,4); hold on;
            plot(m,mean(mean_H2O(i,:)),'o','MarkerFaceColor','k')
            ylabel('H2O')
            subplot(5,2,5); hold on;
            plot(m,mean(pb_interp),'o','MarkerFaceColor','k')
            ylabel('Bubble pressure')
            subplot(5,2,6); hold on;
            plot(m,mean(beta(i,:)),'o','MarkerFaceColor','k')
            ylabel('Compressibility')

            subplot(5,2,7); hold on;
            plot(m,mean(eta(i,:)),'o','MarkerFaceColor','k')
            ylabel('Viscosity')
            subplot(5,2,8); hold on;
            plot(m,mean(u(i,:)),'o','MarkerFaceColor','k')
            ylabel('Velocity')

            subplot(5,2,9); hold on;
            plot(m,mean(Nb(i,:)),'o','MarkerFaceColor','k')
            ylabel('Nb')
            subplot(5,2,10); hold on;
            plot(m,mean(R(i,:)),'o','MarkerFaceColor','k')
            ylabel('Radius')

            n = 1;
            m = m+1;
        end

    end

    dudr_prev2 = dudr_prev;
    dudr_prev = dudr;

    %%%%%%%%%%%%%%%%%%%%%%% figure 3 %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    figure(3)
    
    if rem(i-1,round((nt-1)/10))==0
        ys = {P-P_0,u,mean_H2O,phi,T-273.15};
        xs = {zz_p,zz_u,zz_t,zz_p,zz_t};
        switch Geometry
            case 'Radial'
                for j = 1:5
                    set(f3,'CurrentAxes',ax3(j))
                    hold on;
                    h3 = plot(xs{j}(i,:),ys{j}(i,:),'color',cmap(i,:),'linewidth',linewidth);
                    xlim([0,max(zz_t(:))*1.01])
        
                    ylabel(labels(j))
                    box('on')
                end
                xlabel('Radius (m)')
                for j=1:4
                    set(f3,'CurrentAxes',ax3(j))
                end

            case 'Cylindrical'
                for j = 1:5
                     set(f3,'CurrentAxes',ax3(j))
                     hold on;
                     h3 = plot(ys{j}(i,:),xs{j}(i,:),'color',cmap(i,:),'linewidth',linewidth);
                     ylim([0,max(zz_t(:))*1.01])
        
                    xlabel(labels(j))
                    box('on')
                end
                set(f3,'CurrentAxes',ax3(1))
                ylabel('Height (m)')
        
                for j=2:5
                    set(f3,'CurrentAxes',ax3(j))
                    %yticklabels([])
                end
        end
    drawnow
    end
    
    i = i + 1
end

if t(i-1)>tf
    u = u(1:i-1,:);
    phi = phi(1:i-1,:);
    rho = rho(1:i-1,:);
    drhodt = drhodt(1:i-1,:);
    melt_visc = melt_visc(1:i-1,:);
    eta = eta(1:i-1,:);
    P = P(1:i-1,:);
    H2O = H2O(1:i-1,:,:);
    xH2O = xH2O(1:i-1,:,:);
    mean_H2O = mean_H2O(1:i-1,:);
    R = R(1:i-1,:);
    Nb = Nb(1:i-1,:);
    T = T(1:i-1,:);
    Cc = Cc(1:i-1,:);
    pb = pb(1:i-1,:);
    zz_p = zz_p(1:i-1,:);
    zz_u = zz_u(1:i-1,:);
    zz_t = zz_t(1:i-1,:);
    t = t(1:i-1);
end

colormap(cmap(1:end/2,:))
c = colorbar('Position',[0.93 0.168 0.015 0.7]);
c.Label.String = ['Time (' t_unit ')'];
clim([0,max(t)/t_stretch]);  

%%%%%%%%%%%%%%%%%%%%%%%% figure 4 %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
z2 = n_magma-1;

f4 = figure(4); clf;
f4.Position = [400,100,600,700];
set(gcf,'color','w');

ys = {P-P_0,pb-P-(2.*(SurfTens)./R),mean_H2O,phi};
labels = {'\Delta Pressure (Pa)','Bubble overpressure (Pa)','Mean H2O (wt %)','\phi'};
ax4 = create_axes(4,'vertical');
for j = 1:4
    set(f4,'CurrentAxes',ax4(j))
    hold on;
    for i = 1:length(t)
        h1 = plot(t/t_stretch,ys{j}(:,2),'b','linewidth',linewidth);
        h2 = plot(t/t_stretch,ys{j}(:,z2),'r','linewidth',linewidth);
    end

    ylabel(labels(j))
    box('on')
end

xlabel(['Time (' t_unit ')'])
for j=1:3
    set(f4,'CurrentAxes',ax4(j))
    xticklabels([])
end
plot(t/t_stretch,SolFun(T(:,2),P(:,2)),'b--','linewidth',linewidth);
plot(t/t_stretch,SolFun(T(:,z2),P(:,z2)),'r--','linewidth',linewidth);

legend([h1,h2],'z=' + string(z_p(2)) + ' m',...
    'z=' + string(z_p(z2)) + ' m')

%%%%%%%%%%%%%%%%%%%%% figure 5 %%%%%%%%%%%%%%%%%%%%%%%%%
f5 = figure(5); clf;
f5.Position = [400,100,600,700];
set(gcf,'color','w');

ys = {mean_H2O,R,Nb, phi};
labels = {'H2O (wt %)','Bubble radius (m)','Bubble number density','\phi'};

ax5 = create_axes(4,'vertical');
for j = 1:4
    set(f5,'CurrentAxes',ax5(j))
    hold on;
    for i = 1:length(t)
        h1 = plot(t/t_stretch,ys{j}(:,2),'b','linewidth',linewidth);
        h2 = plot(t/t_stretch,ys{j}(:,z2),'r','linewidth',linewidth);
    end

    ylabel(labels(j))
    box('on')
end
xlabel(['Time (' t_unit ')'])
for j=1:3
    set(f5,'CurrentAxes',ax5(j))
    xticklabels([])
end

legend([h1,h2],'z=' + string(z_p(2)) + ' m',...
    'z=' + string(z_p(z2)) + ' m')

%%%%%%%%%%%%%%%%%%%%%%%%% figure 6 %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
f6 = figure(6); clf;
f6.Position = [400,100,600,700];
set(gcf,'color','w');

ys = {phi,u,Cc};
labels = {'\phi','Velocity (m/s)','Cc'};

ax6 = create_axes(3,'vertical');
for j = 1:3
    set(f6,'CurrentAxes',ax6(j))
    hold on;
    for i = 1:length(t)
        h1 = plot(t/t_stretch,ys{j}(:,2),'b','linewidth',linewidth);
        h2 = plot(t/t_stretch,ys{j}(:,z2),'r','linewidth',linewidth);
    end

    ylabel(labels(j))
    box('on')
end
xlabel(['Time (' t_unit ')'])
for j=1:2
    set(f6,'CurrentAxes',ax6(j))
    xticklabels([])
end

set(ax6(3),'YScale','log')

legend([h1,h2],'z=' + string(z_p(2)) + ' m',...
    'z=' + string(z_p(z2)) + ' m')

%%%%%%%%%%%%%%%%%%%%%%%%% figure 7 %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
f7 = figure(7); clf;
f7.Position = [400,100,600,700];
set(gcf,'color','w');

ys = {P-P_0,u,T-273.15,phi};
labels = {'\Delta P (Pa)','Velocity (m/s)','Temperature (^oC)','Vesciularity'};

ax7 = create_axes(4,'vertical');
for j = 1:4
    set(f7,'CurrentAxes',ax7(j))
    hold on;
    for i = 1:length(t)
        h1 = plot(t/t_stretch,ys{j}(:,2),'b','linewidth',linewidth);
        h2 = plot(t/t_stretch,ys{j}(:,z2),'r','linewidth',linewidth);
    end

    ylabel(labels(j))
    box('on')
end
xlabel(['Time (' t_unit ')'])
for j=1:3
    set(f7,'CurrentAxes',ax7(j))
    xticklabels([])
end

legend([h1,h2],'z=' + string(z_p(2)) + ' m',...
    'z=' + string(z_p(z2)) + ' m')
end

% Supporting functions

%The coefficients from Pitzer and Sterner, 1994
function Coeff = coefficients()
% matrix of coefficients for eqs. in Pitzer & Sterner 1994
b=zeros(10,6);
b(1,3)=0.24657688e6;
b(1,4)=0.51359951e2;
b(2,3)=0.58638965e0;
b(2,4)=-0.28646939e-2;
b(2,5)=0.31375577e-4;
b(3,3)=-0.62783840e1;
b(3,4)=0.14791599e-1;
b(3,5)=0.35779579e-3;
b(3,6)=0.15432925e-7;
b(4,4)=-0.42719875e0;
b(4,5)=-0.16325155e-4;
b(5,3)=0.56654978e4;
b(5,4)=-0.16580167e2;
b(5,5)=0.76560762e-1;
b(6,4)=0.10917883e0;
b(7,1)=0.38878656e13;
b(7,2)=-0.13494878e9;
b(7,3)=0.30916564e6;
b(7,4)=0.75591105e1;
b(8,3)=-0.65537898e5;
b(8,4)=0.18810675e3;
b(9,1)=-0.14182435e14;
b(9,2)=0.18165390e9;
b(9,3)=-0.19769068e6;
b(9,4)=-0.23530318e2;
b(10,3)=0.92093375e5;
b(10,4)=0.12246777e3;
Coeff = b;
end

function rho = density(P,T,b)
% convert P to bars from input (pascals)
P = P.*1e-5; %1 pascal a 1e-5 bars

a=zeros(10,length(T));
for i=1:10
    a(i,:)=b(i,1).*T.^-4 + b(i,2).*T.^-2 + b(i,3).*T.^-1 +...
        b(i,4) + b(i,5).*T + b(i,6).*T.^2;
end
% PRT = P/RT where P [bars], R [cm^3*bar/K/mol] and T [K]
PRT = P./(83.14472*T);

rho = 0*T';
% solve implicit equation for rho and convert to kg/m^3
for i=1:length(T)
rho(i) = fzero(@PS_myfun,0.001,[],a(:,i),PRT(i))*18.01528*1000;
end
end

% the function from Pitzer & Sterner 1994, which takes the matrix of
% coefficients a and P/RT as arguments; rho is a first guess for the
% density [g/mol]
function y = PS_myfun(rho,a,PRT)
y = (rho+a(1)*rho^2-rho^2*((a(3)+2*a(4)*rho+3*a(5)*rho^2+4*a(6)*rho^3)/((a(2)+a(3)*rho+a(4)*rho^2+a(5)*rho^3+a(6)*rho^4)^2))+a(7)*rho^2*exp(-a(8)*rho)+a(9)*rho^2*exp(-a(10)*rho)) - PRT;
end

function [h1,h2,A,B,C,D,E,F] = FDcoeff(z)
h1 = [z(2)-z(1), z(2:end-1)-z(1:end-2), z(end-1)-z(end-2)];
h2 = [z(3)-z(2), z(3:end)-z(2:end-1), z(end)-z(end-1)];
A = (2*h1 + h2)./h1./(h1+h2);
B = (h1+h2)./h1./h2;
C = h1./(h1+h2)./h2;
D = h2./h1./(h1+h2);
E = (h1-h2)./h1./h2; 
F = (h1 + 2*h2)./h2./(h1+h2);
end

function W = Mass_SingleOxygen(Composition)

comp = Composition';

%Convert composition matrix from Viscosity input to Shishkina format
%!! SiO2 TiO2 Al2O3 FeO(T) MnO MgO CaO Na2O K2O P2O5 H2O F2O-1 !!
%Convert To
%!! SiO2 TiO2 Al2O3 Fe2O3 FeO MnO MgO CaO Na2O K2O P2O5 Cr2O3] !!

X = zeros(12,1);
X(1) = comp(1);
X(2) = comp(2);
X(3) = comp(3);
X(4) = 0;
X(5) = comp(4);
X(6) = comp(5);
X(7) = comp(6);
X(8) = comp(7);
X(9) = comp(8);
X(10) = comp(9);
X(11) = comp(10);
X(12) = 0;


Total_Mass = sum(X);

%Molar mass (g/mol) of individual elements
mSi = 28.0855;
mTi = 47.867;
mAl = 26.981539;
mFe = 55.845;
mMn = 54.938044;
mMg = 24.305;
mCa = 40.078;
mNa = 22.989769;
mK = 39.0983;
mP = 30.973762;
mCr = 51.9961;
mO = 15.999;

% [SiO2 TiO2 Al2O3 Fe2O3 FeO MnO MgO CaO Na2O K2O P2O5 Cr2O3]
%Molar mass (g/mol) of oxides
OxideMolarMass = zeros(12,1);
OxideMolarMass(1) =  (mSi+2*mO);
OxideMolarMass(2) = (mTi+2*mO);
OxideMolarMass(3) = (2*mAl+3*mO);
OxideMolarMass(4) = (2*mFe+3*mO);
OxideMolarMass(5) = (1*mFe+1*mO);
OxideMolarMass(6) = (1*mMn+1*mO);
OxideMolarMass(7) = (1*mMg+1*mO);
OxideMolarMass(8) = (1*mCa+1*mO);
OxideMolarMass(9) = (2*mNa+1*mO);
OxideMolarMass(10) = (2*mK+1*mO);
OxideMolarMass(11) = (2*mP+5*mO);
OxideMolarMass(12) = (2*mCr+3*mO);

%Compute number of moles of element, and Cation Fraction
numMolesOxygen = [2 2 3 3 1 1 1 1 1 1 5 3]';
numMolesElement = [1 1 2 2 1 1 1 1 2 2 2 2]';

%Compute the number of moles of each oxide
Moles_Oxide = X./OxideMolarMass;

%Compute moles of oxygen by stoichiometry
Moles_Oxygen = Moles_Oxide.*numMolesOxygen;

%W_melt is the mass of anhydrous melt per mole of oxygen
W = Total_Mass./sum(Moles_Oxygen);
end
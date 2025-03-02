function [w_hat, cdiag, hypers_estimation, w_dif, sq_er] = runsDRD(prs0,datastruct,lb,ub,iters,init_bound,truth)
% Initialization for hyperparameters
nd = datastruct.nd;
if isempty(prs0)
    kmle = datastruct.x\datastruct.y; % get mle estimator
    rho0 = norm(kmle); % initial marginal variance
    delta0 = nd/10; % initial delta
    b = -12; % mean
    log_nsevar0 = 0; % initial log of noise variance
    len0 = 10; % initial length scale for smoothing kernel
    hypers_init = [rho0, delta0, log_nsevar0, len0];
else
    b = -12; % mean
    hypers_init = prs0;
end

% Set up for optimization
% iters = 200;
ind = [1,2,3,4]; % index of hypers for estimation: 1 rho, 2 delta, 3 log_nsevar, 4 len
nind = setdiff([1:4],ind); % index of hypers not for estimation
opt.cond = 1e12^(1/numel(nd)); % condthresh for optimization
opt.svMin = 1e-6; % threshold for cutting off cdiag
opt.nonlinearity = 'rec'; % choose the nonlinearity for transforming u
opt.iikeep = true(prod(nd),1); % elements to keep apriori
opt.th_c = 1; % flag for thresholding cdiag
frac = 0.8; % the fraction for shrinking delta
DCmult = sqrt(prod(nd)); % factor to multiply by dc term
mindelta = lb(ind==2); % minimal delta
minl = lb(ind==4); % minimal len

% options for optimizing u
options.Method='lbfgs';
options.TolFun=1e-5;
options.MaxIter = 100;
options.maxFunEvals = 100;
options.Display = 'off';

% options for optimizing hypers
options_hypers = optimset('display', 'off', 'maxIter', 100, ...
    'Algorithm', 'interior-point', 'TolFun', 1e-5, 'TolX', 1e-5);

% Initialize with random value within bounds
if init_bound
    hypers_init(ind) = (ub(ind)-lb(ind)).*rand(length(lb(ind)),1) + lb(ind);
end
% % Or initialize with true hypers
% hypers_init = hyper_true;
hypers_estimation = zeros(iters,4);
hypers_estimation(1,:) = hypers_init;

w_hat_old = inf*ones(sum(opt.iikeep),1);
sq_er = inf*ones(iters,1); % square error
w_dif = inf*ones(iters,1); % change of w

%% The main loop
time = cputime; % starting time
for iter = 2:iters
    display([ 'iter: ' num2str(iter)])
    
    % Get hypers from the previous iteration
    rho = hypers_estimation(iter-1,1);
    delta = hypers_estimation(iter-1,2);
    fracdelta = max([mindelta,frac*delta]); % shrink delta with a fraction
    log_nsevar = hypers_estimation(iter-1,3);
    datastruct.log_nsevar = log_nsevar; % log_nsevar is passed into the function through datastruct
    len = hypers_estimation(iter-1,4);
    fraclen = max([minl,frac*len]); % shrink len with a fraction
    
    % Generate diagonal of Fourier-defined SE covariance (both K and b are generated in the frequency domain)
    [logkdiag, wnrm, G] = mkcov_logASDfactored_nD(rho,delta,nd,fracdelta,nd(:),opt.cond); % G is Bfft
    kdiag = exp(logkdiag);
    DCterm = logical(prod(wnrm==0,2));
    ld = length(kdiag); opt.ld = ld; % dimension in the frequency domain
    invK = 1./kdiag;
    if isinf(sum(invK))
        invK1 = invK; invK1(invK1==inf)=[]; invK(invK==inf) = max(invK1);
    end
    bp = sparse(ld,1); bp(DCterm) = b*DCmult; % b in the frequency domain
    opt.b = b;
    
    % Generate frequency covariance
    [logcfdiag, ~, Gf] = mkcov_logASDfactored_nD(1,len,nd,fraclen,nd(:),opt.cond); % G is Bfft
    cfdiag = exp(logcfdiag);
    
    % Optimize in v space
    if iter == 2 % initialization for v
        v0 = 0.0001*ones(ld,1);
    else
        if size(v_new,1)<ld % if the length of v_new is longer than ld, take of high frequency components.
            m_v_new = ceil(length(v_new)/2);
            dv = ld-size(v_new,1);
            v0 = [v_new(1:m_v_new); zeros(dv,1); v_new(m_v_new+1:end)];
        else % if the length of v_new is shorter than ld, fill in zeros for high frequency components.
            m_v0 = ceil(ld/2);
            v0 = [v_new(1:m_v0); v_new(end-m_v0+2:end)];
        end
    end
    
    % lbfgs
    fun = @(var) obj_v_dual_sdrd(var, datastruct, bp, kdiag, G, cfdiag, Gf, opt);
    v_new = minFunc(fun, v0, options);
    ufreq_new = v_new.*sqrt(kdiag)+bp; % get new ufreq
    ureal_new = kronmulttrp(G,ufreq_new); % get new ureal
    
    % Get Hessian matrix for data likelihood
    L = DataLikelihood_Hessian_sdrd(ufreq_new, datastruct, G, cfdiag, Gf, opt);
    logkdiag_old = logkdiag;
    
    %% Calculate w_hat from ureal_new, w_hat is the MAP estimate
    X = datastruct.x;
    y = datastruct.y;
    n = size(X,1);
    cdiag = nonlinear_u(ureal_new(opt.iikeep==1),opt,-opt.b); % get new cdiag
    cdiag = abs(cdiag);
    cdiag_half = sqrt(cdiag);
    cfdiag_half = sqrt(cfdiag);
    XCs = bsxfun(@times, X, cdiag_half');
    XCs1 = zeros(size(XCs,1),length(opt.iikeep));
    XCs1(:,opt.iikeep) = XCs;
    XCs = XCs1;
    XCsB = kronmult(Gf,XCs')';
    XCsBCf = bsxfun(@times, XCsB, cfdiag_half');
    nsevar = exp(hypers_estimation(iter-1,3)); % nsevar from the previous iter
    S = XCsBCf*XCsBCf'+ nsevar*speye(n); % S matrix
    invS = S\eye(size(S));
    X1 = kronmulttrp(Gf,bsxfun(@times,XCsBCf,cfdiag_half')')';
    w_hat = bsxfun(@times,X1(:,opt.iikeep),cdiag_half')'*invS*y; % derive w_hat in dual form
    w_hat1 = zeros(size(opt.iikeep)); w_hat1(opt.iikeep==1) = w_hat; % w_hat with the orignal length if truncated
    
    % Plot w_hat, ureal and cdiag, compared with true values
    subplot(311),plot([w_hat1 truth.w_true]); title(['w']), drawnow
    subplot(312),plot([ureal_new truth.u_true]); title('u'), drawnow
    subplot(313),plot([(nonlinear_u(ureal_new,opt,-opt.b)) truth.c_true]); title('cdiag'), drawnow
    
    %% Set bounds for optimizing hypers
    r_bound = [rho*frac, rho/frac]; % bounds for rho
    d_bound = [delta*frac, delta/frac]; % bounds for delta
    n_bound = [log_nsevar+log(2), log_nsevar-log(2)]; % bounds for log_nsevar
    l_bound = [len*frac, len/frac]; % bounds for len
    
    optlb = lb(ind);
    optlb(ind==1) = max([lb(1),min(r_bound)]);
    optlb(ind==2) = max([lb(2),min(d_bound)]);
    optlb(ind==3) = max([lb(3),min(n_bound)]);
    optlb(ind==4) = max([lb(4),min(l_bound)]);
    
    optub = ub(ind);
    optub(ind==1) = min([ub(1),max(r_bound)]);
    optub(ind==2) = min([ub(2),max(d_bound)]);
    optub(ind==3) = min([ub(3),max(n_bound)]);
    optub(ind==4) = min([ub(4),max(l_bound)]);
    
    % Initialize hypers
    hypers0 = (optub-optlb).*rand(length(optlb),1) + optlb; % hypers for estimation
    nonhypers0 = hypers_estimation(iter-1,nind); % hypers not for estimation
    
    f_hypers = @(hypers) obj_hyp_sdrd(hypers, nonhypers0, [ind nind], ureal_new, ...
        v_new, logkdiag_old, L, datastruct, fracdelta, fraclen, opt);
    fval = f_hypers(hypers0);
    if fval==1e50
        % if fval from random initialized hypers is 1e50, try hypers from
        % previous iter
        hypers0 = hypers_estimation(iter-1,ind);
        nonhypers0 = hypers_estimation(iter-1,nind);
    end
    f_hypers = @(hypers) obj_hyp_sdrd(hypers, nonhypers0, [ind nind], ureal_new, ...
        v_new, logkdiag_old, L, datastruct, fracdelta, fraclen, opt);
    [hypers_new, fval] = fmincon(f_hypers,hypers0,[],[],[],[],optlb,optub,[],options_hypers);
    
    % collect new hypers
    hypers_estimation(iter,ind) = hypers_new;
    hypers_estimation(iter,nind) = nonhypers0;
    sq_er(iter) = norm(datastruct.y-datastruct.x*w_hat)/norm(datastruct.y);
    w_dif(iter) = norm(w_hat-w_hat_old);
    w_hat_old = w_hat;
    
    display(['rho: ' num2str(hypers_estimation(iter,1)) ...
        ' delta: ' num2str(hypers_estimation(iter,2)) ...
        ' nsevar: ' num2str(exp(hypers_estimation(iter,3))) ...
        ' len: ' num2str(hypers_estimation(iter,4)) ...
        ' w dif: ' num2str(w_dif(iter)) ' sq_er: ' num2str(sq_er(iter))])
    if w_dif(iter)<1e-3
        break;
    end
end
time = cputime-time; % final time





function [neglogev,grad,H,mupost,Lpost] = neglogev_ridgeDual(prs,dat)
% Neg log-evidence for ridge regression model
%
% [neglogev,grad,H,mupost,Lpost] = neglogev_ridge(prs,dat)
%
% Computes negative log-evidence:
%    -log P(Y|X,sig^2,C)
% under linear-Gaussian model:
%       y = x'*w + n,    % linear observation model
%       n ~ N(0,sig^2),  % observation noise
%       w ~ N(0,rho*I),  % prior on weights
% Traditional ridge parameter is sig^2/rho
%
% INPUTS:
% -------
%  prs [2 x 1] - ridge model parameters [rho (marginal var); nsevar].
%                (also accepts struct with these fields)
%
%  dat - data structure with fields:
%        .xx - stimulus autocovariance matrix X*X' in Fourier domain
%        .xy - stimulus-response cross-covariance X'*Y in Fourier domain
%        .yy - response variance Y'*Y
%        .ny - number of samples
%
% OUTPUT:
% -------
%  neglogev [1 x 1] - negative marginal likelihood
%      grad [n x 1] - gradient
%         H [n x n] - hessian
%    mupost [n x 1] - posterior mean
%     Lpost [n x n] - posterior covariance
%
% Updated 2015.03.30 (mca)

% Unpack parameters
if isstruct(prs)
    rho = prs.rho;
    nsevar = prs.nsevar;
else
    rho = prs(1);
    nsevar = prs(2);
end

[ny, nx] = size(dat.x);
Y = dat.y;
X = dat.x;
XX = dat.xx;
XY = X'*Y/nsevar;
sigdiag = nsevar*ones(ny,1);
sig = spdiags(sigdiag,0,ny,ny);

if nargout == 1 % Compute neglogli
    % dual form
    M = rho*XX + sig;
    trm1 = .5*logdet(rho*XX + sig);%log-determinant term
    trm2 = .5*Y'*(M\Y);%Quadratic term
    neglogev = trm1 + trm2;
elseif nargout == 2 % compute neglogli and gradient
    sig = spdiags(nsevar*ones(ny,1),0,ny,ny);
    M = rho*XX + sig;
    MY = M\Y;
    
    %  --- Compute neg-logevidence ---- primal form
    trm1 = .5*logdet(rho*XX + sig);%log-determinant term
    trm2 = .5*Y'*MY;%Quadratic term
    neglogev = trm1 + trm2;
    
    % --- Compute gradient ------------
    
    % Deriv w.r.t noise variance 'nsevar'
    MX = M\X;
    dLdthet = -.5*trace(MX*X') +.5*Y'*(MX*MX')*Y;
    
    % Deriv w.r.t noise variance 'nsevar'
    RR = .5*(MY'*MY);
    Traceterm = -.5*sum(1./eig(M));
    dLdnsevar = Traceterm+RR;
    
    
    % Combine them into gardient vector
    grad = -[dLdthet; dLdnsevar];
    
elseif nargout == 3 % compute neglogli, gradient, & Hessian
    sig = spdiags(nsevar*ones(ny,1),0,ny,ny);
    M = rho*XX + sig;
    MY = M\Y;
    
    %  --- Compute neg-logevidence ---- primal form
    trm1 = .5*logdet(rho*XX + sig);%log-determinant term
    trm2 = .5*Y'*MY;%Quadratic term
    neglogev = trm1 + trm2 + ny*log(2*pi)/2;
    
    % --- Compute gradient ------------
    % Derivs w.r.t hyperparams rho and len
    MX = M\X;
    dLdthet = -.5*trace(MX*X') +.5*Y'*(MX*MX')*Y;
    
    % Deriv w.r.t noise variance 'nsevar'
    RR = .5*(MY'*MY);
    Traceterm = -.5*sum(1./eig(M));
    dLdnsevar = Traceterm+RR;
    
    % Combine them into gardient vector
    grad = -[dLdthet; dLdnsevar];
    
    % --- Compute Hessian ------------
    
    % theta terms (rho and len)
    MXX = M\XX;
    trm1 = .5*trace(MXX*MXX);%trace term
    trm2 = -Y'*MXX*MXX*MY;%quadratic term
    ddLddthet = trm1+trm2;
    
    % nsevar term
    trm1 = .5*sum(1./eig(M).^2);%trace term
    trm2 = -MY'*(M\MY);
    ddLdv = trm1 + trm2;
    
    % Cross term theta - nsevar
    trm1 = .5*trace(M\MXX');%trace term
    trm2 = -MY'*MXX*MY;%Quadratic term 1
    ddLdthetav = trm1 + trm2;
    % <<<<<<< HEAD
    H = -unvecSymMtxFromTriu([ddLddthet;ddLdthetav; ddLdv]);
    
elseif nargout > 3 % compute other stuff we might want (MAP estimate, posterior cov)
    
    XX2 = X'*X;
    mdcinv = -(1/rho)*ones(nx,1); % multiplier for deriv of C^-1 w.r.t theta (simplify!)
    cdiag = rho*ones(nx,1);  % diagonal of prior covariance
    Cinv = spdiags(1./cdiag,0,nx,nx); % inverse cov in diagonalized space
    Lpostinv = (XX2/nsevar+Cinv);
    Lpost = inv(Lpostinv);
    Lpdiag = diag(Lpost);
    mupost = Lpost*XY/nsevar;
    sig = spdiags(nsevar*ones(ny,1),0,ny,ny);
    M = rho*XX + sig;
    MY = M\Y;
    
    %  --- Compute neg-logevidence ---- primal form
    trm1 = .5*logdet(rho*XX + sig);%log-determinant term
    trm2 = .5*Y'*MY;%Quadratic term
    neglogev = trm1 + trm2 + ny*log(2*pi)/2;
    
    % --- Compute gradient ------------
    % Derivs w.r.t hyperparams rho and len
    MX = M\X;
    dLdthet = -.5*trace(MX*X') +.5*Y'*MX*MX'*Y;
    
    % Deriv w.r.t noise variance 'nsevar'
    RR = .5*MY'*MY;
    Traceterm = -.5*sum(1./eig(M));
    dLdnsevar = Traceterm+RR;
    
    % Combine them into gardient vector
    grad = -[dLdthet; dLdnsevar];
    
    % --- Compute Hessian ------------
    
    % theta terms (rho and len)
    MXX = M\XX;
    MMY = M\(MY);
    trm1 = .5*trace(MXX*MXX);%trace term
    trm2 = -Y'*MXX*MXX*MY;%quadratic term
    ddLddthet = trm1+trm2;
    
    % nsevar term
    trm1 = .5*sum(1./eig(M).^2);%trace term
    trm2 = -MY'*(M\MY);
    ddLdv = trm1 + trm2;
    
    % Cross term theta - nsevar
    trm1 = .5*trace(M\MXX');%trace term
    trm2 = -MY'*MXX*MY;%Quadratic term 1
    ddLdthetav = trm1 + trm2;
    H = -unvecSymMtxFromTriu([ddLddthet;ddLdthetav; ddLdv]);
    
    % =======
    %     H = -unvecSymMtxFromTriu([ddLddthet;ddLdthetav; ddLdv]);
    % >>>>>>> DevASDdata
end

#include "rid.hpp"
#include "types.hpp"
#include "gemm.hpp"
#include "random.hpp"
#include "util.hpp"
#include "handle.hpp"
#include "print.hpp"
#include "timer.hpp"
#include "submatrix.hpp"
#include "permute.hpp"


void RandLUPP(const double *A, int m, int n, int k,
    int *&sk, int *&rd, double *&T, double &flops) {

  Timer t;

  t.start();
  dvec Gmat(n*k);
  dvec Ymat(m*k);
  if (!sk) CHECK_CUDA( cudaFree(sk) );
  if (!rd) CHECK_CUDA( cudaFree(rd) );
  if (!T)  CHECK_CUDA( cudaFree(T)  );
  CHECK_CUDA( cudaMalloc((void **) &sk, sizeof(int)*k) );
  CHECK_CUDA( cudaMalloc((void **) &rd, sizeof(int)*(m-k) ));
  CHECK_CUDA( cudaMalloc((void **) &T,  sizeof(double)*k*(m-k) ));
  t.stop(); double t4 = t.elapsed_time();
  

  t.start();
  //Gaussian(Gmat, 0., 1./std::sqrt(k));
  Random::Gaussian(Gmat, 0., 1.);
  t.stop(); double t0 = t.elapsed_time();
  
  
  t.start();
  double *G = thrust::raw_pointer_cast( Gmat.data() );
  double *Y = thrust::raw_pointer_cast( Ymat.data() );
  GEMM(m, k, n, A, G, Y);
  t.stop(); double t1 = t.elapsed_time();

  
  t.start();
  dvec work; // working memory for LU
  ivec ipiv(k); // local permutation
  ivec info(1); // an integer on gpu

  // query working space
  int lwork = 0;
  auto const& handle = Handle_t::instance();
  CUSOLVER_CHECK( cusolverDnDgetrf_bufferSize(handle.solver, m, k, Y, m, &lwork) );
  work.resize(lwork);
  
  // compute factorization
  CUSOLVER_CHECK( cusolverDnDgetrf(handle.solver, m, k, Y, m, 
        thrust::raw_pointer_cast(work.data()), 
        thrust::raw_pointer_cast(ipiv.data()), 
        thrust::raw_pointer_cast(info.data()) ));
  assert( info[0]==0 );
  t.stop(); double t2 = t.elapsed_time();

  // permutation indices
  t.start();
  ivec P(m);
  thrust::sequence(P.begin(), P.end(), 0);
  pivots_to_permutation(ipiv, P);
  t.stop(); double t6 = t.elapsed_time();

  
  t.start();
  double one = 1.0;
  CHECK_CUBLAS( cublasDtrsm(handle.blas, CUBLAS_SIDE_RIGHT, CUBLAS_FILL_MODE_LOWER,
        CUBLAS_OP_N, CUBLAS_DIAG_UNIT, m-k, k, &one, Y, m, Y+k, m) );
  t.stop(); double t3 = t.elapsed_time();
  //print(Ymat, m, k, "Y");


  t.start();
  thrust::copy_n( P.begin(), k, iptr(sk) );
  thrust::copy_n( P.begin()+k, m-k, iptr(rd) );
  
  auto zero = thrust::make_counting_iterator<int>(0);
  auto indx = thrust::make_transform_iterator(zero, SubMatrix(m-k, m));
  auto elem = thrust::make_permutation_iterator(dptr(Y+k), indx);
  thrust::copy_n( elem, k*(m-k), dptr(T) );
  t.stop(); double t5 = t.elapsed_time();


  flops = 2.*m*n*k + 2.*m*k*k/3. + 1.0*k*k*(m-k);


#ifdef PROF
  std::cout<<std::endl
    <<"--------------------\n"
    <<"  RandLUPP\n"
    <<"--------------------\n"
    <<"Alloc: "<<t4<<std::endl
    <<"Rand:  "<<t0<<std::endl
    <<"GEMM:  "<<t1<<std::endl
    <<"LUPP:  "<<t2<<std::endl
    <<"Solve: "<<t3<<std::endl
    <<"Copy:  "<<t5<<std::endl
    <<"Perm:  "<<t6<<std::endl
    <<"--------------------\n"
    <<"Total: "<<t0+t1+t2+t3+t4+t5+t6<<std::endl
    <<"--------------------\n"
    <<std::endl;
#endif
}


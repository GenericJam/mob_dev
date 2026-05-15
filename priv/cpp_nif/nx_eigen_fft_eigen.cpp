// nx_eigen_fft_eigen.cpp — Eigen-backed FFT implementation of the
// nx_eigen_fft.h C contract.
//
// We ship this in mob_dev (not in upstream nx_eigen) so the on-device
// path through `mix mob.enable nxeigen` gets `Nx.fft` working without
// a separate FFTW cross-compile. Eigen's FFT module ships kissfft as
// the default backend — header-only, embedded in the Eigen tarball at
// unsupported/Eigen/FFT — so this file plus the Eigen headers gives
// us a complete pluggable FFT with no external library dep.
//
// ## Contract delta vs FFTW
//
// nx_eigen_fft.h spec:
//   * Forward unnormalised:  X[k]   = Σ x[n] · exp(-2πi nk/N)
//   * Inverse unnormalised:  X̃[k]  = Σ x[n] · exp(+2πi nk/N)
//   * Caller divides the IDFT by n.
//
// Eigen's `FFT<>` defaults match this for `fwd` (kissfft is unscaled)
// but its `inv` divides by N unless `Unscaled` flag is set. We set
// the flag on every transform so the contract holds exactly.
//
// ## Layout
//
// The C contract is interleaved real/imag floats:
//   [re_0, im_0, re_1, im_1, ..., re_{n-1}, im_{n-1}]
// `std::complex<float>` and `std::complex<double>` are guaranteed by
// C++ to have this exact layout (sizeof = 2 × sizeof(scalar), no
// padding, real then imag). Bitwise-compatible reinterpret_cast.
//
// ## Performance note
//
// Eigen's default kissfft backend is roughly 2× slower than FFTW for
// large transforms but typically microseconds for audio-sized buffers
// (≤8192). If a future workload measures a real bottleneck, swap to
// FFTW via a parallel `nx_eigen_fft_fftw.cpp` cross-compile — the
// pluggable contract was designed for exactly that.

#include "nx_eigen_fft.h"

#include <complex>
#include <unsupported/Eigen/FFT>

namespace {

template <typename Scalar>
int fft_forward(const Scalar *in, Scalar *out, int n) {
  if (n <= 0) {
    return 1;
  }
  Eigen::FFT<Scalar> fft;
  fft.SetFlag(Eigen::FFT<Scalar>::Unscaled);

  const auto *src = reinterpret_cast<const std::complex<Scalar> *>(in);
  auto *dst = reinterpret_cast<std::complex<Scalar> *>(out);

  // Eigen's `fwd(dst, src, n)` accepts overlapping buffers (kissfft
  // copies internally), so the contract's in-place allowance holds.
  fft.fwd(dst, src, static_cast<Eigen::Index>(n));
  return 0;
}

template <typename Scalar>
int fft_inverse(const Scalar *in, Scalar *out, int n) {
  if (n <= 0) {
    return 1;
  }
  Eigen::FFT<Scalar> fft;
  fft.SetFlag(Eigen::FFT<Scalar>::Unscaled);

  const auto *src = reinterpret_cast<const std::complex<Scalar> *>(in);
  auto *dst = reinterpret_cast<std::complex<Scalar> *>(out);

  fft.inv(dst, src, static_cast<Eigen::Index>(n));
  return 0;
}

}  // namespace

extern "C" {

int nx_eigen_fft_forward_f32(const float *in, float *out, int n) {
  return fft_forward<float>(in, out, n);
}

int nx_eigen_fft_forward_f64(const double *in, double *out, int n) {
  return fft_forward<double>(in, out, n);
}

int nx_eigen_fft_inverse_f32(const float *in, float *out, int n) {
  return fft_inverse<float>(in, out, n);
}

int nx_eigen_fft_inverse_f64(const double *in, double *out, int n) {
  return fft_inverse<double>(in, out, n);
}

}  // extern "C"

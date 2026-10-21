// 内存带宽测试（STREAM 风格的 copy / triad，多线程）。用法：membw [线程数=4] [每个数组 MB=128]
// 输出最好的一次：copy 按 2×数组大小、triad 按 3×数组大小计字节（和 STREAM 相同的计法）。
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double *A, *B, *C; static long N; static int T, MODE;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static void *work(void *p) { long id = (long)p, lo = N * id / T, hi = N * (id + 1) / T;
  if (MODE == 0) for (long i = lo; i < hi; i++) C[i] = A[i];
  else for (long i = lo; i < hi; i++) A[i] = B[i] + 3.0 * C[i];
  return NULL; }
static double run(int mode) { pthread_t th[64]; MODE = mode; double t0 = now();
  for (long i = 0; i < T; i++) pthread_create(&th[i], NULL, work, (void *)i);
  for (int i = 0; i < T; i++) pthread_join(th[i], NULL);
  return now() - t0; }
int main(int argc, char **argv) {
  T = argc > 1 ? atoi(argv[1]) : 4; long mb = argc > 2 ? atol(argv[2]) : 128; N = mb * 1024 * 1024 / 8;
  A = malloc(N * 8); B = malloc(N * 8); C = malloc(N * 8);
  for (long i = 0; i < N; i++) { A[i] = 1; B[i] = 2; C[i] = 0; }
  double bc = 1e9, bt = 1e9;
  for (int r = 0; r < 8; r++) { double c = run(0), t = run(1); if (c < bc) bc = c; if (t < bt) bt = t; }
  printf("threads=%d array=%ldMB copy=%.2f GB/s triad=%.2f GB/s\n", T, mb, 2.0 * N * 8 / bc / 1e9, 3.0 * N * 8 / bt / 1e9);
  return 0; }

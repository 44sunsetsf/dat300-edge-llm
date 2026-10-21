// 轻量资源采集器（scripts/monitor.sh 的 C 版本，开销可以忽略）：一个常驻进程，每隔 interval 毫秒
// 读 /proc/stat、/proc/meminfo、/proc/<pid>/statm、/sys/class/net/<if>/statistics，输出一行 CSV（列同 monitor.sh）。
// 用法：mon 输出.csv [间隔毫秒=500] [网卡=eth0]      编译：scripts/build_tools.sh（Docker 里静态编译 arm64）
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static long long rd(const char *p) { FILE *f = fopen(p, "r"); long long v = 0; if (f) { if (fscanf(f, "%lld", &v) != 1) v = 0; fclose(f); } return v; }

static void rss(long long *rpc, long long *bench) {   // 常驻内存（kB），按进程名分两类
  *rpc = *bench = 0; long pg = sysconf(_SC_PAGESIZE) / 1024;
  DIR *d = opendir("/proc"); struct dirent *e; char p[300], c[64];
  if (!d) return;
  while ((e = readdir(d))) {
    if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
    snprintf(p, sizeof p, "/proc/%s/comm", e->d_name);
    FILE *f = fopen(p, "r"); if (!f) continue;
    if (!fgets(c, sizeof c, f)) { fclose(f); continue; } fclose(f);
    int isr = !strncmp(c, "ggml-rpc-server", 15), isb = !strncmp(c, "llama-bench", 11) || !strncmp(c, "llama-batched-b", 15);
    if (!isr && !isb) continue;
    snprintf(p, sizeof p, "/proc/%s/statm", e->d_name);
    f = fopen(p, "r"); long long sz = 0, res = 0;
    if (f) { if (fscanf(f, "%lld %lld", &sz, &res) != 2) res = 0; fclose(f); }
    if (isr) *rpc += res * pg; else *bench += res * pg;
  }
  closedir(d);
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: mon out.csv [interval_ms] [iface]\n"); return 1; }
  int ms = argc > 2 ? atoi(argv[2]) : 500; const char *ifc = argc > 3 ? argv[3] : "eth0";
  FILE *o = fopen(argv[1], "w"); if (!o) return 1;
  fprintf(o, "ts_ms,user,nice,system,idle,iowait,irq,softirq,mem_total_kb,mem_avail_kb,rpc_rss_kb,bench_rss_kb,rx_bytes,tx_bytes,rx_packets,tx_packets,temp_mc\n");
  char sp[4][160]; const char *k[4] = {"rx_bytes", "tx_bytes", "rx_packets", "tx_packets"};
  for (int i = 0; i < 4; i++) snprintf(sp[i], sizeof sp[i], "/sys/class/net/%s/statistics/%s", ifc, k[i]);
  for (;;) {
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    long long c[7] = {0}, mt = 0, ma = 0, r, b; char line[256];
    FILE *f = fopen("/proc/stat", "r");
    if (f) { if (fscanf(f, "cpu %lld %lld %lld %lld %lld %lld %lld", &c[0], &c[1], &c[2], &c[3], &c[4], &c[5], &c[6]) != 7) {} fclose(f); }
    f = fopen("/proc/meminfo", "r");
    if (f) { while (fgets(line, sizeof line, f)) { sscanf(line, "MemTotal: %lld", &mt); sscanf(line, "MemAvailable: %lld", &ma); } fclose(f); }
    rss(&r, &b);
    fprintf(o, "%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld\n",
            (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000, c[0], c[1], c[2], c[3], c[4], c[5], c[6], mt, ma, r, b,
            rd(sp[0]), rd(sp[1]), rd(sp[2]), rd(sp[3]), rd("/sys/class/thermal/thermal_zone0/temp"));
    fflush(o);
    struct timespec sl = {ms / 1000, (ms % 1000) * 1000000L}; nanosleep(&sl, NULL);
  }
}

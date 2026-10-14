# 最终报告（LaTeX）

- `main.tex`：报告正文（英文）。第 7、8、9 节是 2026-10-14 交换机 + 4 台 Pi 的实验，数据来自 `../docs/实验报告_1014.md` 和 `../logs/`。
- `figures/`：报告里的所有图（PDF 和 PNG 各一份），由 `make_figures.py` 生成。
- `make_figures.py`：画图脚本。【在笔记本上】运行 `python3 report/make_figures.py`（需要 matplotlib）。每块数据都注明了来自哪个测试编号的日志；每 token 时间拆分图直接读取 `logs/trace/` 里的计时日志。
- `main_preview.pdf`：本地编译的预览。本地的 tectonic 没有 gelasio 字体，所以预览用的是默认字体；在 Overleaf 上编译会用 gelasio。

编译：把 `main.tex` 和 `figures/` 一起上传到 Overleaf，或者本地 `tectonic main.tex`。

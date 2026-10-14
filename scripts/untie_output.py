#!/usr/bin/env python3
# 给"输出层和嵌入层共用一个矩阵"（tied embedding）的 GGUF 模型补一个独立的 output.weight。
#
# 为什么：llama.cpp 的 TP（-sm tensor）会把 output.weight 按词表切到每台机器上，
# 但 token_embd.weight 是每台都存一整份、每台都完整计算（MIRRORED）。Llama-3.2-3B 没有 output.weight，
# 输出层直接用 token_embd，所以 TP 时每台都要完整算一遍输出层（4 台时每台约 80 ms/token，不随台数减少）。
# 补上 output.weight（内容就是 token_embd 的拷贝，量化类型不变，所以结果完全一样）以后，输出层就能按台数切分。
#
# 用法（在笔记本上，需要 numpy）：
#   python3 scripts/untie_output.py 输入.gguf 输出.gguf [--embd-from 另一个.gguf]
#   --embd-from：token_embd 改用另一个模型里的（比如快速模型里 Q4_0 的 token_embd），output.weight 仍然拷贝自输入模型
# gguf-py 来自 llama.cpp 源码（../llama.cpp-dat300/gguf-py），或者 pip install gguf。
import argparse, os, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "..", "..", "llama.cpp-dat300", "gguf-py"))
import gguf  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("inp"); ap.add_argument("out"); ap.add_argument("--embd-from")
a = ap.parse_args()

r = gguf.GGUFReader(a.inp)
names = [t.name for t in r.tensors]
if "output.weight" in names:
    sys.exit("这个模型已经有 output.weight 了，不需要处理")
emb = next(t for t in r.tensors if t.name == "token_embd.weight")
emb_new = emb
if a.embd_from:
    emb_new = next(t for t in gguf.GGUFReader(a.embd_from).tensors if t.name == "token_embd.weight")

arch = r.fields[gguf.Keys.General.ARCHITECTURE].contents()
w = gguf.GGUFWriter(a.out, arch=arch, endianess=r.endianess)
for f in r.fields.values():
    if f.name == gguf.Keys.General.ARCHITECTURE or f.name.startswith("GGUF."):
        continue
    vt = f.types[0]; st = f.types[-1] if vt == gguf.GGUFValueType.ARRAY else None
    w.add_key_value(f.name, f.contents(), vt, sub_type=st)

# 张量顺序：原来的张量（token_embd 可能被替换）+ 末尾的 output.weight
tensors = [emb_new if t.name == "token_embd.weight" else t for t in r.tensors]
for t in tensors:
    w.add_tensor_info("token_embd.weight" if t is emb_new else t.name, t.data.shape, t.data.dtype, t.data.nbytes, t.tensor_type)
w.add_tensor_info("output.weight", emb.data.shape, emb.data.dtype, emb.data.nbytes, emb.tensor_type)
w.write_header_to_file(); w.write_kv_data_to_file(); w.write_ti_data_to_file()
for t in tensors:
    w.write_tensor_data(t.data, tensor_endianess=r.endianess)
w.write_tensor_data(emb.data, tensor_endianess=r.endianess)
w.close()
print(f"已生成 {a.out}：output.weight = {emb.tensor_type.name}，token_embd = {emb_new.tensor_type.name}，"
      f"{os.path.getsize(a.out)/1e9:.2f} GB")

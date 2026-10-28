# Final presentation script (15 min)

Slides: [`slides.pdf`](slides.pdf). About 2,000 words, which is roughly 14 minutes at a normal speaking pace, leaving a little buffer.
The speaker split below is only a suggestion (four parts of about 3.5 minutes each); change it as you like.

| Part | Slides | Time | Speaker |
|---|---|---|---|
| A. Background and setup | 1–5 | 3:30 | ? |
| B. Results, bottlenecks 1–2 | 6–8 | 3:30 | ? |
| C. Bottleneck 3, network, 10 Mbit/s | 9–11 | 3:30 | ? |
| D. PP, RK3588, problems, conclusions | 12–15 | 3:30 | ? |

---

## Part A — Background and setup (3:30)

**Slide 1 — Title (0:20)**
Hi everyone, we are group 7. Our project is about running a large language model on a cluster of small edge devices, in our case Raspberry Pis.

**Slide 2 — Outline (0:15)**
We'll start with the background and our setup, then show our results and the bottlenecks we found, and end with conclusions.

**Slide 3 — Why run an LLM on edge devices? (1:00)**
Most people use LLMs through the cloud. That means your data leaves your device, and you need a connection.
A single Raspberry Pi can run a small model locally, but it is slow.
So our question was: if we connect several cheap boards, can they run one model together and be faster?
We had four research questions: how speed scales with the number of nodes, whether pipeline or tensor parallelism is better, what the bottleneck is, and whether we can fix it without losing accuracy.
For all experiments we used Llama 3.2 with 3 billion parameters, quantized to 4 bits, so the model file is about 1.9 GB.

**Slide 4 — Our cluster (0:50)**
This is our actual setup in the lab. We have seven Raspberry Pis, some Pi 400s, which are the keyboards, and some Pi 4Bs, plus one faster board with an RK3588 chip, the grey box at the back. Everything is connected to one Gigabit switch.
The table shows one important number: memory bandwidth. A Pi reads memory at about 4 GB per second. To generate one token the model has to read all 1.9 GB of weights, so one Pi gets about 1.8 tokens per second. The RK3588 has five times the bandwidth and is about seven times faster.

**Slide 5 — How we ran and measured it (1:05)**
We started with Distributed Llama as a baseline on one, two and four nodes. For the main experiments we switched to llama.cpp, because its RPC backend lets us compare two ways of splitting the model.
With pipeline parallelism, each device gets a block of layers, and the token passes through the devices one after the other.
With tensor parallelism, every layer is split across all devices, so they all work at the same time, but they have to synchronise twice per layer.
To find out *why* something was slow, we measured two things: a small monitor on every device that records CPU, memory and network every half second, and a timing log inside llama.cpp that shows how much time each node spends computing, synchronising or just waiting.

---

## Part B — Results and bottlenecks 1–2 (3:30)

**Slide 6 — Decode speed from 1 to 8 nodes (1:10)**
This is our main result: decode speed, so how many tokens per second we generate, from one to eight nodes.
Pipeline parallelism is never faster than a single Pi. That is expected: only one device is working at any time.
Stock tensor parallelism actually gets *slower* when we add nodes. On eight nodes it only reaches 0.41 tokens per second.
After our changes we get 6.34 tokens per second on eight nodes. That's 3.4 times faster than one Pi.
So what was wrong with the stock version? We found three bottlenecks, and I'll go through them one by one.

**Slide 7 — Bottleneck 1: all traffic goes through the head (1:10)**
In tensor parallelism, after each part of a layer, the nodes need to add up their partial results. This is called an allreduce.
Stock llama.cpp only does this directly between nodes when there are exactly two. With more nodes, the head downloads all the partial results, adds them up and sends them back.
On four nodes the head sends about 50 MB for every single token, as you can see on the left.
We changed it so that the nodes exchange data directly with each other, in log-two-of-N steps. On four nodes that took us from 1.03 to almost 3 tokens per second.

**Slide 8 — Bottleneck 2: the output layer is not split (1:10)**
Then we looked at the timing log. Each bar is one node. Even after the first fix, every node spent 80 to 85 milliseconds per token on the very last layer, the output layer, no matter how many nodes we had.
The reason is that Llama 3.2 shares this layer with the input embedding. llama.cpp then copies the whole layer to every node instead of splitting it.
Our fix was to store a separate copy of that layer in the model file. The output is exactly the same, and we checked that the perplexity does not change. Now the layer gets split like the others, and four nodes went from 3 to 4.85 tokens per second, about 60 percent faster.

---

## Part C — Bottleneck 3, network, 10 Mbit/s (3:30)

**Slide 9 — Bottleneck 3: the head's CPU at 8 nodes (1:15)**
When we went from four to eight nodes, the speed suddenly dropped again, to 1.6 tokens per second.
Our resource monitor showed why: the head's CPU was at 94 percent, while the workers were almost idle at 15 percent. The timing log agreed: of 631 milliseconds per token, workers spent 470 just waiting for the head.
We attached gdb to the head and found that llama.cpp runs one thread per remote node, and these threads busy-wait, so they spin even when there is nothing to do. With eight nodes that's eight spinning threads on a 4-core Pi, and the threads doing real work don't get the CPU.
We added an option that lets these threads sleep instead. That took eight nodes from 1.62 to 6.34 tokens per second, almost four times faster.

**Slide 10 — Is the network the bottleneck? (1:00)**
A natural guess is that the network is the problem. We checked this with the monitor.
On Gigabit Ethernet, each worker used at most 233 out of 940 megabits per second, so about a quarter of the link.
And the strongest argument: when we fixed bottleneck 3, the network traffic stayed exactly the same, but the speed went up almost four times. So the network was not what limited us.
For a single Pi, the limit is memory bandwidth, as we saw earlier.

**Slide 11 — What if the network is slow? (1:15)**
But edge devices don't always have a fast network. So we limited all eight devices to 10 megabits per second and compared stock llama.cpp with our version.
The stock version pushes 200 MB per token through the head, the link is completely full, and it generates one token about every 100 seconds, 0.01 tokens per second.
With our direct allreduce, the head only handles 5.3 MB per token, and we get 0.2 to 0.26 tokens per second.
That's 20 to 26 times faster, compared with 15 times on Gigabit. So reducing the traffic matters even more when the network is slow.

---

## Part D — PP, RK3588, problems, conclusions (3:30)

**Slide 12 — Pipeline parallelism and a faster board (1:10)**
Two shorter results.
On the left, pipeline parallelism. For a single request it can't be faster than one board. With several requests at the same time, the stages can overlap, and we got 29 percent more throughput. So the real use of pipeline parallelism is to fit a model that is too big for one board, not to make it faster.
On the right, the RK3588. Just compiling llama.cpp for its CPU doubled its speed, from 5.8 to 12.3 tokens per second. In a mixed cluster, giving the fast board a bigger share helps a lot. But honestly, for this model, the RK3588 alone is faster than our whole Pi cluster.

**Slide 13 — Problems we ran into (0:50)**
Not everything went smoothly. The switch was reset and lost its DHCP settings, so we gave every board a fixed IP. One Pi kept rebooting in the middle of a test, and the cause turned out to be a weak power supply. The Pis have no real-time clock, so we had to correct the clock offsets before we could compare logs from different devices. And our first monitoring script was a shell script that slowed decoding down by 5 percent, so we rewrote it as a small C program.

**Slide 14 — Conclusions and future work (1:10)**
To sum up and answer our questions:
Tensor parallelism scales to 3.4 times on eight Pis. Pipeline parallelism does not speed up a single request.
Tensor parallelism needs much more communication, but on Gigabit Ethernet the network was not the limit. The real limits were things that don't get smaller when you add nodes: the head relaying all traffic, the unsplit output layer, and the head's CPU.
All three fixes are small changes, and none of them affects accuracy.
For future work, we'd like to support uneven splits for mixed devices, try models that are too big for one board, and reduce the number of synchronisation rounds per token.

**Slide 15 — Thank you (0:10)**
Thank you for listening. We're happy to take questions.

---

## Possible questions

- **Why not just use the RK3588?** For this 3B model it is the better choice. The cluster becomes useful for models that don't fit on one board, and when only weak devices are available.
- **Does untying the output layer change the model?** No. It is an exact copy of the same weights, the output tokens are identical and the perplexity is the same.
- **Why only powers of two?** Recursive doubling pairs nodes up in each step; uneven or non-power-of-two node counts fall back to the head relay. That is our main future work.
- **How reliable are the numbers?** Each configuration was run 1–2 times with the monitor on; the monitor costs at most 2–3 percent. The trends are much larger than that noise.
- **Why does PP not help?** With one request, layers run in sequence, so only one device works at a time; PP only adds memory, not speed.

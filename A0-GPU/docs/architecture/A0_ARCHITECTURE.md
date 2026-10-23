# A0 GPU Architecture Specification



Version: 0.1

Status: Research / Pre-RTL

Target: High-performance gaming + compute GPU architecture



## 1. Mission



A0 is the first generation of a scalable GPU architecture intended to evolve

from software simulation and FPGA prototypes into a commercial ASIC family.



The long-term product target includes:



\- High-end gaming GPU

\- General-purpose GPU compute

\- Hardware ray tracing

\- Matrix / AI acceleration

\- Vulkan support

\- DirectX support

\- Windows and Linux drivers

\- Shader compiler

\- Runtime and developer SDK

\- PCIe graphics cards

\- Future chiplet and advanced-memory designs



The FPGA implementation is a prototype and is NOT the final performance target.



## 2. Primary Design Goals



The architecture must optimize for:



1\. Gaming performance

2\. Performance per watt

3\. Performance per mm^2

4\. Low and predictable frame time

5\. Memory bandwidth efficiency

6\. Compute throughput

7\. Scalability

8\. Programmability

9\. Compiler friendliness

10\. Verification and testability



## 3. Execution Model



A0 uses a SIMT execution model.



Logical wave size:



&#x20;   32 threads - provisional



The logical wave size must be separated from the number of physical execution

lanes.



Initial FPGA prototype:



&#x20;   8 physical lanes - provisional



Example:



&#x20;   Wave = 32 threads

&#x20;   Physical lanes = 8



&#x20;   Cycle group 0 -> threads 0-7

&#x20;   Cycle group 1 -> threads 8-15

&#x20;   Cycle group 2 -> threads 16-23

&#x20;   Cycle group 3 -> threads 24-31



Both WAVE\_SIZE and PHYSICAL\_LANES must be parameterizable.



The final ASIC values will be selected using benchmark and PPA measurements.



## 4. Initial Compute Core



Each prototype compute core will contain:



\- Wave scheduler

\- Instruction fetch

\- Instruction decode

\- Vector register file

\- Scalar register file

\- SIMT integer execution unit

\- Load/store unit

\- Active-thread mask

\- Branch/divergence control

\- Local/shared memory interface



Future units:



\- FP32 execution

\- FP16 execution

\- FMA

\- Special function unit

\- Matrix unit

\- Texture unit

\- Ray-tracing unit



## 5. Register Architecture



Prototype target:



Scalar registers:



&#x20;   S0-S31



Vector registers:



&#x20;   V0-V63



Vector registers contain one logical value per active thread.



Register counts are provisional and must remain configurable during research.



## 6. Initial Data Types



Required:



\- INT32

\- UINT32

\- FP32



Planned:



\- INT16

\- INT8

\- FP16

\- BF16

\- FP8

\- INT4



## 7. Graphics Pipeline Target



The complete graphics pipeline will eventually contain:



&#x20;   Command Processor

&#x20;          |

&#x20;   Graphics Front End

&#x20;          |

&#x20;     Vertex Shader

&#x20;          |

&#x20;   Primitive Assembly

&#x20;          |

&#x20;    Triangle Setup

&#x20;          |

&#x20;      Rasterizer

&#x20;          |

&#x20;    Fragment Shader

&#x20;          |

&#x20;     Texture Units

&#x20;          |

&#x20;    Depth / Stencil

&#x20;          |

&#x20;         ROP

&#x20;          |

&#x20;     Framebuffer



## 8. Compute Architecture Target



Future compute hierarchy:



&#x20;   GPU

&#x20;    |

&#x20;    +-- Compute Cluster

&#x20;    |     |

&#x20;    |     +-- Shader Core

&#x20;    |     +-- Shader Core

&#x20;    |     +-- Shader Core

&#x20;    |     +-- Shader Core

&#x20;    |

&#x20;    +-- Compute Cluster

&#x20;    +-- Compute Cluster

&#x20;    +-- ...



The number of cores and clusters must be scalable.



## 9. Ray Tracing Target



Future hardware acceleration will investigate:



\- BVH traversal

\- Bounding-box intersection

\- Triangle intersection

\- Ray scheduling

\- Shader interaction



No ray-tracing ISA encoding is frozen in v0.1.



## 10. Matrix / AI Target



Future matrix hardware will investigate:



\- FP16 matrix operations

\- BF16

\- FP8

\- INT8

\- INT4

\- Mixed precision



AI acceleration must not compromise the primary gaming architecture.



## 11. Memory Hierarchy Target



Initial conceptual hierarchy:



&#x20;   Registers

&#x20;      |

&#x20;   Shared / Local Memory

&#x20;      |

&#x20;     L1 Cache

&#x20;      |

&#x20;     L2 Cache

&#x20;      |

&#x20;   Memory Controllers

&#x20;      |

&#x20;   External Memory



Prototype memory may use FPGA RAM/DDR.



Future products may use:



\- GDDR

\- HBM

\- Large last-level caches

\- Chiplet memory fabrics



## 12. Host Interface



Prototype:



\- Simulation

\- FPGA host interface



Future:



\- PCI Express

\- DMA engines

\- Interrupts

\- Virtual memory

\- IOMMU integration

\- Resizable BAR-like large memory mappings



## 13. Software Stack



A0 is not hardware-only.



Required software stack:



&#x20;   Game / Application

&#x20;         |

&#x20;   Vulkan / DirectX

&#x20;         |

&#x20;      Driver

&#x20;         |

&#x20;   Shader Compiler

&#x20;         |

&#x20;      A0 ISA

&#x20;         |

&#x20;       GPU



Development components:



\- ISA simulator

\- Assembler

\- Shader compiler

\- Runtime

\- Vulkan driver

\- Windows kernel/user-mode driver

\- Linux driver

\- Debugger

\- Profiler

\- Benchmark suite



## 14. Verification Strategy



Every hardware block should have:



\- Reference software model

\- Unit tests

\- RTL testbench

\- Randomized testing where applicable

\- Assertions

\- Regression tests



For every instruction:



&#x20;   software-model result == RTL result



must hold.



## 15. Development Generations



A0-SIM0

&#x20;   ISA and execution simulator



A0-RTL0

&#x20;   First integer SIMT execution core



A0-RTL1

&#x20;   Branching, masks, load/store



A0-FP0

&#x20;   FP32/FP16 execution



A0-GFX0

&#x20;   Programmable vertex/fragment pipeline



A0-GFX1

&#x20;   Rasterizer, texture, depth and ROP



A0-FPGA0

&#x20;   First complete FPGA graphics prototype



A0-ASIC0

&#x20;   First experimental silicon



Future generations:

&#x20;   multi-core GPU

&#x20;   high-performance memory system

&#x20;   ray tracing

&#x20;   matrix acceleration

&#x20;   high-end commercial GPU



## 16. Open Architecture Questions



The following are deliberately NOT frozen:



\- Wave size: 16 / 32 / 64?

\- Physical SIMD width?

\- Number of schedulers per core?

\- Register-file organization?

\- Scalar/vector ISA split?

\- Instruction encoding width?

\- Cache sizes?

\- Cache line size?

\- Shared-memory design?

\- Divergence/reconvergence algorithm?

\- Issue width?

\- Dual-issue?

\- Graphics/compute resource sharing?

\- Texture architecture?

\- RT unit architecture?

\- Matrix unit architecture?



These decisions will be made using simulation, benchmarks and later PPA data.



## 17. First Milestone



A0-SIM0 must execute a logical wave of threads using an initial instruction set.



First validation program:



&#x20;   VADD V3, V1, V2

&#x20;   VMUL V4, V3, V5

&#x20;   VSUB V6, V4, V7

&#x20;   STORE V6

&#x20;   HALT



The same program will later be executed by RTL and compared against the

software reference model.




## 18. SIM15 Scheduler Policy Study

SIM15 introduces measured LRR, GTO, oldest-ready, and an initial A0 adaptive
wave-selection candidate in the timing simulator. It also adds an opt-in coarse
model of the live RTL6B banked-vector frontend so register-bank pressure can be
included in scheduling experiments without changing the historical default
timing semantics.

The first matrix rejects unconditional GTO as a universal policy: locality can
improve while latency hiding regresses. `a0_adaptive_v0` therefore remains LRR
unless predicted active memory working-set pressure exceeds L2 capacity and a
same-wave memory streak is available.

This is a research candidate, not a frozen scheduler. Full rationale, metrics,
initial measurements, and verification are in:

`docs/architecture/A0_SIM15_SCHEDULER_STUDY.md`

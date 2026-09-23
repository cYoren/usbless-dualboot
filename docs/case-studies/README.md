# Case studies

Real runs on real hardware. Each one records the exact configuration, the steps taken, and the
lessons learned, so others (and agents) can adapt the method.

## Index

| Machine | Direction | OS / boot | Result |
|---|---|---|---|
| [Dell G15 5525](dell-g15-omarchy-limine-windows11.md) | add-windows | Omarchy + Limine + LUKS/Btrfs + Win11 25H2 | Proven |

The full tested scripts for the Dell run are in
[`../../examples/reference-omarchy/`](../../examples/reference-omarchy/).

## Add yours

Copy [`TEMPLATE.md`](TEMPLATE.md) to `docs/case-studies/<machine-slug>.md`, fill it in, and open a
pull request. A useful case study makes these reproducible:

- the exact starting layout (paste `lsblk` and the bootloader),
- the plan your chose (sizes, partitions),
- what worked, and what needed a workaround,
- any distro/bootloader quirks worth encoding in the tool.

Tell us the machine and we will add it to the index.

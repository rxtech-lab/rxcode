# Detailed preset artwork

Robot, Cat, and Puff were generated with the built-in image generation tool on 2026-11-17. The existing `dog-imagegen/closed.png` was used as the style and grid reference. The original character identities were retained: white/cyan ceramic Robot, lavender kitten Cat, and round pink fluffy Puff.

Each directory contains `closed.png` and a mouth-only refinement in `open.png`. The sprite assembler uses the closed body for both speech states and feathers the generated open mouth into the same region, preserving body alignment. The artwork has six illustrated key poses per motion; breathing, sway, and hop transforms expand those into 24 continuation frames. These are not 24 independently illustrated poses.

Run `swift scripts/pet/assemble-imagegen-presets.swift . cat` (or `robot` / `puff`) to create the corresponding pack under `output/pet/detailed-<kind>`. Each pack includes four 1536 × 2048 body sheets, eight speech sheets, frame metadata, and a portable manifest. Copy the atlas and metadata files to the matching `RxCode/Resources/Pet/pet-<kind>-<page>` resources to update the built-in appearance. The procedural generator overwrites these resources; reassemble the detailed artwork afterward.

## Generation prompt

Use case: style-transfer. Production desktop pet animation sprite atlas. Reference image is the detailed Dog style and grid reference only. Replace every puppy with the requested character, retaining its identity. Match the detailed dog's adorable proportions, dimensional studio shading, detailed materials, and polished collectible toy quality. Exact uniform 6 columns by 8 rows, 48 sprites, portrait 3:4 aspect ratio, square cells, transparent alpha background, generous padding, full body inside every cell. Consistent head position, scale, and baseline. Tiny closed mouth centered near x50%, y49% of each cell. Rows: idle breathing and blinking; working with a tiny laptop; curious waiting; sleepy resting; waving; front-facing walking; celebration; disappointment. Six sequential key poses per row. No labels, grid lines, ground plane, watermarks, dogs, or extra creatures.

Character descriptions:

- Robot: friendly white and pale blue ceramic toy robot, dark glass face panel, cyan glowing eyes and digital mouth, short cyan antenna, rounded articulated hands and feet, glossy ceramic and subtle metal joints.
- Cat: lavender kitten, triangular ears with pink interiors, ivory muzzle and tummy, fine lavender plush fur, sparkling violet eyes, pink nose, whiskers, and rounded paws. No floppy dog ears.
- Puff: original nearly spherical pink fluffy creature, tiny rounded arms and feet, curled tuft, glossy dark eyes, rosy cheeks, tiny smile, and detailed soft pink fur. No animal ears.

## Speech refinement prompt

Edit only the tiny mouths of all 48 characters in the exact 6 × 8 atlas. Open every mouth into a small rounded speaking shape: dark with a pink tongue for Cat and Puff, cyan digital for Robot. Preserve eyes, nose, face, head, body, materials, gestures, scale, positions, image dimensions, and transparency. Include resting, working, and gesture rows. No new objects or text.

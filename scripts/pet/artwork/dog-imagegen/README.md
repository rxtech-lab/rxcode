# Detailed Dog source artwork

Generated with the built-in image generation tool on 2026-11-17, using the existing Dog atlas as the identity and grid reference. `closed.png` contains six illustrated key poses per motion. `open.png` refines the same atlas with speaking mouths.

Run `swift scripts/pet/assemble-imagegen-dog.swift` from the repository root to create `output/pet/detailed-dog`. The assembler uses the closed body for both speech states, feathering only the generated mouth region from the open atlas. It expands the six key poses into 24 frames per motion through small breathing, sway and hop transforms. These are six illustrated poses with transform-based continuation, rather than 24 independently drawn poses.

The portable pack contains four 1536 × 2048 sheets and their speech companions, totaling 37,748,736 pixels. The app bundle uses the same sheets as `RxCode/Resources/Pet/pet-dog-{1…4}*.png` and matching 256 px frame manifests. Running the older procedural `generate-pets.swift` overwrites the bundled Dog; reassemble and copy this pack afterward to retain the detailed artwork.

## Initial prompt

Use case: style-transfer. Asset: production desktop pet animation sprite atlas. Edit the referenced Dog atlas into a MUCH more detailed and adorable premium soft 3D toy puppy, preserving EXACT 6 columns by 8 rows uniform grid, 48 separate full-body sprites, transparent background, no labels. Golden apricot fur with individual soft tufts, floppy caramel ears, creamy muzzle and tummy, tiny glossy chocolate nose, huge warm sparkling brown eyes, rosy cheeks, tiny paws with pads, charming chubby proportions. Beautiful soft dimensional studio shading; clean readable silhouette at 112px. Keep the same dog identity, front view, full body, scale, and baseline across all cells. Keep generous transparent padding around every sprite. Each sprite has a tiny CLOSED smiling mouth below the nose. Rows in order: 1 idle breathing blinking; 2 working tapping a tiny laptop; 3 waiting curious head tilt; 4 resting sleepy eyes closed; 5 waving one paw; 6 walking front-facing alternating feet; 7 celebrating raised paws; 8 disappointed ears drooped. Each row has six different sequential key poses progressing left to right. Strictly 48 sprites in an evenly spaced 6x8 grid, no extra objects between cells, no ground plane, no background, no text, no watermark. Produce a portrait atlas with 3:4 aspect ratio.

## Cleanup refinement

Preserve all 48 puppies and their grid. Remove colored background contamination and ground shadows, retaining actual transparent alpha and clean fur edges.

## Speech refinement

Edit only the tiny mouths of all 48 puppies in the exact 6 × 8 atlas. Open every mouth into a small dark rounded speaking shape with a pink tongue below the nose. Preserve nose, eyes, fur, head, body, pose, scale and position. Keep the transparent background. The assembler limits this refinement to each mouth region to guarantee body alignment.

The source PNGs contain very low-opacity edge pixels whose saturated RGB values can appear bright in an alpha-unaware viewer. Normal premultiplied-alpha composition displays clean edges; preserve the generated alpha.

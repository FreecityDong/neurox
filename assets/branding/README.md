# NeuroX brand assets

- Original reference: `docs/logo.png`, retained unchanged.
- Launcher icon master: `assets/branding/neurox-mark.png`, 1024 × 1024, opaque PNG.
- In-app mark: `assets/branding/neurox-mark-transparent.png`, transparent PNG. `NeuroxMark` draws it directly, with no background or rounded-square clipping. Homepage, account pages and profile share this asset.
- The app mark omits both the NeuroX wordmark and the CARE · CONNECT · EMPOWER tagline. The in-app product name is normal UI text, separate from the icon.
- Editing mode: built-in `image_gen.imagegen` (imagegen skill), followed by macOS `sips` resizing for platform resources. The master is an edited derivative of the supplied image, not a pixel-exact crop.
- Regenerate platform sizes: `python3 scripts/generate-brand-icons.py` on macOS. iOS sizes come from the existing AppIcon Contents.json; Android includes all five launcher densities; Web includes normal/maskable icons and favicon.
- Palette: primary teal `#397F80`, sage `#BDD6A5`, mist blue `#7EAFC7`, ink `#263F43`, light background `#F5F9F7`. Pale logo colors are accents; text/buttons use deeper colors for readability. Functional red/green status and chart semantics are retained.
- Theme implementation: `lib/ui/neurox_brand.dart`. Light and dark modes share the same palette and rounded card/input/navigation styling. No new page flows or task algorithms are introduced.

## Image editing prompt

Use case: precise-object-edit. Edit target: supplied NeuroX logo. Create the actual square app icon asset. Remove ALL lettering below the brain/tree symbol, including NeuroX and CARE CONNECT EMPOWER. Preserve the original brain-shaped branching tree and open circular arc faithfully: same branches, round tips, soft left pale sage-green to teal to right mist-blue gradient and thin organic lines. Do not redesign or add elements. Recenter the symbol alone horizontally and vertically on a clean pure white opaque square background; symbol/outer arc should occupy about 80 percent of width and height with comfortable equal margins. No lettering anywhere, no shadows, no rounded-square border, no extra graphics. Clean crisp edges suitable for a 1024-square app icon. Save resulting image to a local file and return its path.

## In-app transparency edit (2026-11-04)

Built-in imagegen edit, with `transparent_background: true`, using the current opaque master as the edit target. Launcher master and generated platform icons remain unchanged. Alpha and actual light/dark Flutter page renders are checked; asset source under Codex generated_images is copied into the project.

Prompt: Use case: background-extraction. Edit this existing NeuroX brain-tree and open circular arc logo. REMOVE ONLY THE WHITE BACKGROUND, making it genuinely transparent alpha everywhere between branches and outside the colored strokes, including the inside of the brain silhouette and ring. Preserve the current colored lines, fine branches, tips, outlines, exact geometry, existing sage green to teal to blue gradients, composition, scale, and square canvas/padding as faithfully as possible. This is a background-removal task, not a redesign. No white square, no white silhouette fill, no white halo around the lines, no backdrop, no checkerboard baked into the image, no shadow, no new text, no new graphics. Output a transparent PNG suitable to overlay directly on both light and dark app surfaces. Keep the logo positioned and sized identically to the supplied reference. Save output to a local file and return its path.

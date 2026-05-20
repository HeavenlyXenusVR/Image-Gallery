# Image Gallery AI Vision Training

This patch adds a gallery-specific training memory around the existing vision analyzer.
It does **not** pretend to fine-tune a model inside the web server. Instead, it records your owner-approved corrections and feeds those examples back into the vision prompt and local analyzer so future uploads learn your naming, category, subcategory, and tag style.

## What learns automatically

When `GALLERY_AI_AUTO_TRAIN_ON_EDIT=true` (default), every owner edit to a media item stores a training example in `ai_vision_training_examples`.

That means the normal workflow is enough:

1. Upload/analyze media.
2. Correct the title/category/subcategory/tags if the AI is weak.
3. Save the edit.
4. Future analysis receives those corrections as examples.

## Seed training from your existing gallery

After applying the patch and restarting the backend once so the table is created, seed examples from your already-curated uploads:

```bash
cd "$HOME/Documents/Image Gallery"
python3 scripts/seed_ai_vision_training_from_gallery.py --username YOUR_USERNAME --limit 1000
```

Preview without writing:

```bash
python3 scripts/seed_ai_vision_training_from_gallery.py --username YOUR_USERNAME --limit 50 --dry-run
```

## Useful environment toggles

```env
GALLERY_AI_AUTO_TRAIN_ON_EDIT=true
GALLERY_AI_TRAINING_EXAMPLES_LIMIT=24
```

Use a higher limit if your prompt/model can handle more examples. The default keeps analysis fast and avoids overloading local models.

## API endpoints

List your training examples:

```http
GET /api/ai/vision/training?limit=50
```

Export JSONL training data:

```http
GET /api/ai/vision/training/export?limit=500
```

Manually train from a media item:

```http
POST /api/media/{media_id}/ai/train
Content-Type: application/json

{
  "title": "Aria Blaze Wallpaper",
  "category_name": "My Little Pony",
  "subcategory_name": "Aria Blaze",
  "tags": ["aria-blaze", "dazzlings", "mlp"],
  "is_adult": false,
  "notes": "Correct character/category mapping"
}
```

## Best results

The training memory is strongest when filenames, tags, descriptions, or previous corrections include meaningful words like character/franchise names. For purely visual recognition, use a real vision provider such as Ollama with a VLM or a cloud vision model; this patch feeds your gallery-specific corrections into those prompts too.

## Training from an image-only ZIP/folder

If you have a compressed character/reference dataset, seed visual exemplars like this:

```bash
cd "$HOME/Documents/Discord Bots/Image Gallery"
source .venv/bin/activate

python3 scripts/seed_ai_vision_training_from_image_zip.py \
  "$HOME/Pictures/iCloud_Photos_AI_TRAINING_UNDER_512MB.zip" \
  --username HeavenlyXenusVR \
  --review-jsonl "$HOME/Pictures/icloud_ai_training_review.jsonl" \
  --dry-run
```

Review the JSONL if desired. Then insert the clean, high-confidence rows:

```bash
python3 scripts/seed_ai_vision_training_from_image_zip.py \
  "$HOME/Pictures/iCloud_Photos_AI_TRAINING_UNDER_512MB.zip" \
  --username HeavenlyXenusVR \
  --review-jsonl "$HOME/Pictures/icloud_ai_training_review.jsonl"
```

This does not fake a model fine-tune. It stores visual fingerprints plus corrected character/franchise metadata in `ai_vision_training_examples`. During future analysis, the gallery first checks whether a new image visually matches a learned exemplar, then uses Ollama/Gemini/OpenAI if configured, and only falls back to local filename/dimension heuristics last.

Useful test:

```bash
python3 scripts/test_ai_vision_model.py --no-ai --training-jsonl "$HOME/Pictures/icloud_ai_training_review.jsonl" /path/to/test-image.png
```

If `source` says `visual-training`, the dataset memory is working. If it says `heuristic`, there was no close visual match and the backend should use a real vision model such as Ollama/Gemini/OpenAI.

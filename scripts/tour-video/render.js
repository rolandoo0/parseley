// Renders the explainer videos from their HTML timelines, frame by frame, into MP4.
//   node scripts/tour-video/render.js                 → App/Resources/ParseleyTour.mp4 (full tour)
//   node scripts/tour-video/render.js sum out.mp4     → the short ">sum" explainer
//   node scripts/tour-video/render.js tour x 10,20    → PNG snapshots at 10 s and 20 s (for checking)
// Needs Playwright with Chromium and ffmpeg. Each page exposes window.render(t) that
// draws the frame at t seconds, so the output is deterministic.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const dir = __dirname;
const root = path.join(dir, '..', '..');
const logo = path.join(root, 'App/Resources/Assets.xcassets/AppLogo.imageset/logo_512.png');
const videos = {
  tour: { src: 'tour.html', fps: 24, duration: 94, out: path.join(root, 'App/Resources/ParseleyTour.mp4') },
  sum: { src: 'sum.html', fps: 30, duration: 27, out: path.join(dir, 'sum.mp4') },
};
const video = videos[process.argv[2] || 'tour'];
// timing.json (from make_audio.py plan) stretches scenes to fit the narration: video time
// v maps back to the page's original timeline.
const timingPath = path.join(dir, 'timing.json');
const timing = process.argv[2] !== 'sum' && fs.existsSync(timingPath) ? JSON.parse(fs.readFileSync(timingPath, 'utf8')) : null;
if (timing) video.duration = timing.duration;
function contentTime(v) {
  if (!timing) return v;
  for (const s of timing.segments) {
    if (v >= s.video_start && v < s.video_end) {
      const p = (v - s.video_start) / (s.video_end - s.video_start);
      return s.content_start + p * (s.content_end - s.content_start);
    }
  }
  return timing.segments[timing.segments.length - 1].content_end - 0.001;
}
const out = process.argv[3] && process.argv[3] !== 'x' ? path.resolve(process.argv[3]) : video.out;
const snapshots = process.argv[3] === 'x' ? process.argv[4] : null;

(async () => {
  const html = fs.readFileSync(path.join(dir, video.src), 'utf8')
    .replaceAll('src="LOGO"', `src="data:image/png;base64,${fs.readFileSync(logo).toString('base64')}"`);
  const built = path.join(require('os').tmpdir(), `parseley-${video.src}`);
  fs.writeFileSync(built, html);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  await page.goto('file://' + built);
  if (snapshots) {
    for (const s of snapshots.split(',')) {
      await page.evaluate((t) => window.render(t), contentTime(Number(s)));
      await page.screenshot({ path: path.join(require('os').tmpdir(), `parseley-snap-${s}.png`) });
    }
    await browser.close();
    return console.log('snapshots in', require('os').tmpdir());
  }
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(video.fps), '-i', '-',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20', '-movflags', '+faststart', out]);
  for (let i = 0; i < video.fps * video.duration; i++) {
    await page.evaluate((t) => window.render(t), contentTime(i / video.fps));
    const buf = await page.screenshot({ type: 'png' });
    if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once('drain', r));
  }
  ff.stdin.end();
  await new Promise((r) => ff.on('close', r));
  await browser.close();
  console.log('wrote', out);
})();

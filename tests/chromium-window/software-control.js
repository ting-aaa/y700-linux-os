// Run only when the compatibility profile reports that WebGL 2 is unavailable.
async function drawSoftwareControl() {
    const surface = canvas.cloneNode(false);
    canvas.replaceWith(surface);
    const context = surface.getContext("2d");
    const cssColors = ["#ff0000", "#00ff00", "#0000ff", "#000000"];
    const colors = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [0, 0, 0]];
    report.canvas2d = {frames: 0};
    const start = performance.now();
    for (let frame = 0; frame < requested; frame++) {
        await new Promise(resolve => requestAnimationFrame(resolve));
        for (let cell = 0; cell < 4; cell++) {
            const x = (cell % 2) * 48;
            const y = cell < 2 ? 32 : 0;  // Canvas positions measured from the top.
            const index = (cell + frame % 2) % 4;
            context.fillStyle = cssColors[index];
            context.fillRect(x, y, 48, 32);
            const rgba = context.getImageData(x + 24, y + 16, 1, 1).data;
            if (!colors[index].every((component, i) => component === rgba[i]) || rgba[3] !== 255)
                throw new Error("Canvas 2D pixel mismatch");
        }
        report.canvas2d.frames++;
    }
    report.canvas2d.elapsedMs = Math.round(performance.now() - start);
}

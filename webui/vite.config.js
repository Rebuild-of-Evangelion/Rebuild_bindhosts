import { defineConfig } from 'vite';
import { cpSync, existsSync, mkdirSync } from 'fs';

// Documentation/ is the single source for every doc, but the WebUI fetches
// docs/<name> at runtime, so mirror it into the build output.
const copyDocs = () => ({
    name: 'copy-docs',
    closeBundle() {
        const dest = '../module/webroot/docs';
        if (!existsSync('../Documentation')) return;
        mkdirSync(dest, { recursive: true });
        cpSync('../Documentation', dest, { recursive: true });
    },
});

export default defineConfig({
    base: './',
    plugins: [copyDocs()],
    build: {
        outDir: '../module/webroot',
    },
});

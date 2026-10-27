import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  server: {
    proxy: {
      '/api': { target: 'http://127.0.0.1:8787', ws: true },
      '/health': { target: 'http://127.0.0.1:8787' },
    },
  },
  build: { target: 'es2022' },
});

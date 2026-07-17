import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  server: {
    port: 5173,
    proxy: {
      '/admin-api': {
        target: 'http://127.0.0.1:8082',
        changeOrigin: true,
      },
      // Same-origin proxy to kg-svc (avoids CORS during local dev)
      '/kg-svc': {
        target: 'http://127.0.0.1:8010',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/kg-svc/, ''),
      },
      // Same-origin proxy to core-svc video API (:8081)
      '/core-svc': {
        target: 'http://127.0.0.1:8081',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/core-svc/, ''),
      },
    },
  },
})

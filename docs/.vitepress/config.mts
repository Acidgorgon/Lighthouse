import { defineConfig } from 'vitepress'
import { family } from './theme/family'

const shared = family('lighthouse', '/Lighthouse/')

export default defineConfig({
  ...shared.config,

  lang: 'en-US',
  title: 'Lighthouse',
  description: 'Profiling and live telemetry for Roblox: per-system CPU, frame time, network, memory and real player devices.',

  themeConfig: {
    ...shared.themeConfig,

    nav: [
      { text: 'Guide', link: '/guide/getting-started', activeMatch: '^/guide/' },
      { text: 'Reference', link: '/reference/api', activeMatch: '^/reference/' },
      { text: 'Viewer', link: '/viewer' },
      shared.nav,
      {
        text: 'v0.1.0',
        items: [{ text: 'Releases', link: 'https://github.com/Acidgorgon/Lighthouse/releases' }],
      },
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting started', link: '/guide/getting-started' },
          { text: 'Probes', link: '/guide/probes' },
          { text: 'Overlay', link: '/guide/overlay' },
          { text: 'Network', link: '/guide/network' },
          { text: 'Player telemetry', link: '/guide/telemetry' },
          { text: 'What it costs', link: '/guide/cost' },
          { text: 'Recipe: a slow client frame', link: '/guide/fm-recipes' },
        ],
      },
      {
        text: 'Reference',
        items: [{ text: 'API', link: '/reference/api' }],
      },
      {
        text: 'Tools',
        items: [
          { text: 'Viewer', link: '/viewer' },
          { text: 'Benchmarks', link: '/benchmarks' },
        ],
      },
    ],

    socialLinks: [{ icon: 'github', link: 'https://github.com/Acidgorgon/Lighthouse' }],

    editLink: {
      pattern: 'https://github.com/Acidgorgon/Lighthouse/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },
  },
})

import { createRouter, createWebHistory } from 'vue-router'
import AdminLayout from '../layouts/AdminLayout.vue'
import StrategyVizView from '../views/StrategyVizView.vue'
import KgRetrieveView from '../views/KgRetrieveView.vue'
import VideoManageView from '../views/VideoManageView.vue'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    {
      path: '/',
      component: AdminLayout,
      children: [
        { path: '', redirect: '/strategy' },
        { path: 'strategy', name: 'strategy', component: StrategyVizView },
        { path: 'kg', name: 'kg', component: KgRetrieveView },
        { path: 'videos', name: 'videos', component: VideoManageView },
      ],
    },
  ],
})

export default router

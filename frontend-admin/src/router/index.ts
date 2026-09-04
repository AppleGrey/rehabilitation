import { createRouter, createWebHistory } from 'vue-router'
import AdminLayout from '../layouts/AdminLayout.vue'
import LoginView from '../views/LoginView.vue'
import StrategyVizView from '../views/StrategyVizView.vue'
import KgRetrieveView from '../views/KgRetrieveView.vue'
import VideoManageView from '../views/VideoManageView.vue'
import ProgramView from '../views/ProgramView.vue'
import UserVideoView from '../views/UserVideoView.vue'
import UserManageView from '../views/UserManageView.vue'
import AppReleaseView from '../views/AppReleaseView.vue'
import { isLoggedIn } from '../auth'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: LoginView, meta: { public: true } },
    {
      path: '/',
      component: AdminLayout,
      children: [
        { path: '', redirect: '/strategy' },
        { path: 'strategy', name: 'strategy', component: StrategyVizView },
        { path: 'kg', name: 'kg', component: KgRetrieveView },
        { path: 'videos', name: 'videos', component: VideoManageView },
        { path: 'programs', name: 'programs', component: ProgramView },
        { path: 'uploads', name: 'uploads', component: UserVideoView },
        { path: 'users', name: 'users', component: UserManageView },
        { path: 'releases', name: 'releases', component: AppReleaseView },
      ],
    },
  ],
})

// 前端守卫只负责体验（不让未登录的人看到空壳页面）；真正的拦截在 admin-svc 中间件。
router.beforeEach((to) => {
  if (to.meta.public) return true
  if (!isLoggedIn()) {
    return { name: 'login', query: to.fullPath === '/' ? {} : { next: to.fullPath } }
  }
  return true
})

export default router

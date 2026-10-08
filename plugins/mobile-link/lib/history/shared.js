/**
 * `_link/sessionWindow` / `_link/sessionFind` 共用的小工具：超时与错误文案。
 *
 * 抽出来的理由：这两个助手原先在 `history.js` 里，而窗口、检索、探针三块都要用；
 * 放在这里可以让三块各自成文件（spec 007 T065）。
 */

/// 包一层超时：连接器的入站链是**串行**的，一次不返回的宿主调用会卡住整条链。
export function withTimeout(promise, ms, label) {
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms)
  })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}

export function messageOf(error) {
  if (error === undefined || error === null) return 'unknown error'
  if (typeof error === 'string') return error
  return error.message ?? String(error)
}

import { useState } from "react";
import { TopBar } from "@/components/TopBar";
import { ModuleCard } from "@/components/ModuleCard";
import { useAuth } from "@/hooks/useAuth";
import { ArrowRight, AlertCircle, Check } from "lucide-react";

export default function Register() {
  const { register } = useAuth();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState("");
  const [success, setSuccess] = useState(false);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    if (password !== confirm) {
      setError("两次输入的密码不一致");
      return;
    }
    setLoading(true);
    try {
      await register(username, password);
      setSuccess(true);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  if (success) {
    return (
      <div className="h-screen flex flex-col bg-bg text-fg">
        <TopBar />
        <div className="flex-1 flex items-center justify-center p-6">
          <div className="w-full max-w-sm">
            <ModuleCard label="SUCCESS" meta="02/02">
              <div className="px-4 py-8 text-center space-y-4">
                <Check size={32} className="text-signal mx-auto" strokeWidth={1.5} />
                <p className="text-[14px] text-fg">注册成功</p>
                <p className="text-[12px] text-fg-subtle">
                  现在可以登录开始使用了
                </p>
                <a
                  href="/"
                  className="inline-flex items-center gap-1 border border-accent text-accent font-mono text-[12px] uppercase tracking-[0.12em] rounded-sm px-4 py-2 hover:bg-accent hover:text-bg transition-colors"
                >
                  LOGIN <ArrowRight size={14} />
                </a>
              </div>
            </ModuleCard>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="h-screen flex flex-col bg-bg text-fg">
      <TopBar />

      <div className="flex-1 grid grid-cols-1 lg:grid-cols-[3fr_2fr] min-h-0">
        {/* 左侧品牌区 */}
        <section className="border-r border-border p-8 lg:p-12 flex flex-col justify-between overflow-y-auto">
          <div className="reveal" style={{ animationDelay: "0ms" }}>
            <div className="text-[12px] text-fg-subtle">
              项目代号 002
            </div>
          </div>

          <div className="reveal my-8" style={{ animationDelay: "60ms" }}>
            <h1 className="font-display text-[40px] sm:text-[56px] lg:text-[80px] leading-none tracking-[0.04em]">
              AIIC
              <br />
              CHALLENGE
            </h1>
            <div className="mt-6 max-w-md">
              <p className="text-fg-muted text-[15px] leading-relaxed">
                多模态语音工作站
              </p>
              <p className="mt-2 text-[12px] text-fg-subtle">
                注册账号以同步会话到云端
              </p>
            </div>
          </div>

          <div className="reveal" style={{ animationDelay: "120ms" }}>
            <div className="text-[12px] text-fg-subtle">
              已有账号？
              <a href="/" className="text-accent hover:underline ml-1">
                直接登录 →
              </a>
            </div>
          </div>
        </section>

        {/* 右侧表单 */}
        <section className="overflow-y-auto p-6 lg:p-8 flex items-center">
          <div className="w-full max-w-sm mx-auto reveal" style={{ animationDelay: "180ms" }}>
            <ModuleCard label="AUTH" meta="02/02">
              <form onSubmit={handleSubmit} className="px-4 py-4 space-y-4">
                {error && (
                  <div className="flex items-center gap-2 text-[12px] text-error bg-error/10 px-3 py-2 border border-error/30">
                    <AlertCircle size={14} />
                    {error}
                  </div>
                )}

                <div className="space-y-1">
                  <label className="block text-[12px] text-fg-muted uppercase tracking-[0.12em] font-mono">
                    用户名
                  </label>
                  <input
                    type="text"
                    value={username}
                    onChange={(e) => setUsername(e.target.value)}
                    required
                    minLength={3}
                    maxLength={32}
                    className="w-full bg-overlay border border-border rounded-sm px-3 py-2 text-[14px] text-fg outline-none focus:border-accent transition-colors"
                    placeholder="3-32 个字符"
                  />
                </div>

                <div className="space-y-1">
                  <label className="block text-[12px] text-fg-muted uppercase tracking-[0.12em] font-mono">
                    密码
                  </label>
                  <input
                    type="password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    required
                    minLength={6}
                    className="w-full bg-overlay border border-border rounded-sm px-3 py-2 text-[14px] text-fg outline-none focus:border-accent transition-colors"
                    placeholder="至少 6 位"
                  />
                </div>

                <div className="space-y-1">
                  <label className="block text-[12px] text-fg-muted uppercase tracking-[0.12em] font-mono">
                    确认密码
                  </label>
                  <input
                    type="password"
                    value={confirm}
                    onChange={(e) => setConfirm(e.target.value)}
                    required
                    minLength={6}
                    className="w-full bg-overlay border border-border rounded-sm px-3 py-2 text-[14px] text-fg outline-none focus:border-accent transition-colors"
                    placeholder="再次输入密码"
                  />
                </div>

                <button
                  type="submit"
                  disabled={loading}
                  className="w-full h-9 flex items-center justify-center gap-2 border border-accent text-accent font-mono text-[12px] uppercase tracking-[0.12em] rounded-sm hover:bg-accent hover:text-bg transition-colors disabled:opacity-40"
                >
                  {loading ? (
                    <span className="flex items-center gap-1.5">
                      <span className="pulse-dot-1 inline-block w-1.5 h-1.5 bg-accent" />
                      <span className="pulse-dot-2 inline-block w-1.5 h-1.5 bg-accent" />
                      <span className="pulse-dot-3 inline-block w-1.5 h-1.5 bg-accent" />
                    </span>
                  ) : (
                    <>
                      REGISTER <ArrowRight size={14} />
                    </>
                  )}
                </button>
              </form>
            </ModuleCard>
          </div>
        </section>
      </div>
    </div>
  );
}

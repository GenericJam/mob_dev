defmodule MobDev.Plugin.AuditTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.Audit

  setup do
    dir = Path.join(System.tmp_dir!(), "mob_audit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib"))
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "audit_plugin/2 — clean plugin" do
    test "returns zero findings for a minimal pure-Elixir plugin", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule Clean do
        def hi, do: :ok
      end
      """)

      assert %{findings: [], summary: %{high: 0, medium: 0, low: 0}} =
               Audit.audit_plugin(dir, %{name: :clean})
    end

    test "carries the plugin name from manifest into the report", %{dir: dir} do
      assert %{plugin: :foo} = Audit.audit_plugin(dir, %{name: :foo})
    end

    test "nil manifest yields nil plugin name without crashing", %{dir: dir} do
      assert %{plugin: nil, findings: []} = Audit.audit_plugin(dir, nil)
    end
  end

  describe "audit_plugin/2 — Code.eval_string / compile_string" do
    test "flags Code.eval_string/1", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def go(s), do: Code.eval_string(s)
      end
      """)

      assert %{findings: [f]} = Audit.audit_plugin(dir, %{name: :x})
      assert f.severity == :high
      assert f.rule == :code_eval
      assert f.snippet =~ "eval_string"
      assert is_integer(f.line)
    end

    test "flags Code.eval_string/2 and /3 as well", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def a(s, b), do: Code.eval_string(s, b)
        def c(s, b, opts), do: Code.eval_string(s, b, opts)
      end
      """)

      assert %{findings: findings} = Audit.audit_plugin(dir, %{name: :x})
      assert length(findings) == 2
      assert Enum.all?(findings, &(&1.rule == :code_eval))
    end

    test "flags Code.compile_string/1,2", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def a(s), do: Code.compile_string(s)
        def b(s, f), do: Code.compile_string(s, f)
      end
      """)

      assert %{findings: findings} = Audit.audit_plugin(dir, %{name: :x})
      assert length(findings) == 2
      assert Enum.all?(findings, &(&1.severity == :high and &1.rule == :code_eval))
    end
  end

  describe "audit_plugin/2 — :erlang.binary_to_term" do
    test "flags the unbounded arity-1 form", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def go(bin), do: :erlang.binary_to_term(bin)
      end
      """)

      assert %{findings: [f]} = Audit.audit_plugin(dir, %{name: :x})
      assert f.severity == :high
      assert f.rule == :unsafe_deserialization
    end

    test "does NOT flag the arity-2 :safe form", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def go(bin), do: :erlang.binary_to_term(bin, [:safe])
      end
      """)

      assert %{findings: []} = Audit.audit_plugin(dir, %{name: :x})
    end
  end

  describe "audit_plugin/2 — String.to_atom" do
    test "does NOT flag literal String.to_atom(\"foo\")", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def go, do: String.to_atom("foo")
      end
      """)

      assert %{findings: []} = Audit.audit_plugin(dir, %{name: :x})
    end

    test "flags non-literal String.to_atom(x)", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def go(x), do: String.to_atom(x)
      end
      """)

      assert %{findings: [f]} = Audit.audit_plugin(dir, %{name: :x})
      assert f.severity == :medium
      assert f.rule == :unbounded_atom
    end
  end

  describe "audit_plugin/2 — Application.put_env" do
    test "flags Application.put_env(:mob, ...)", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def go, do: Application.put_env(:mob, :plugins, [:evil])
      end
      """)

      assert %{findings: [f]} = Audit.audit_plugin(dir, %{name: :x})
      assert f.severity == :medium
      assert f.rule == :mob_env_mutation
    end

    test "does NOT flag put_env for other apps or get_env for :mob", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def a, do: Application.put_env(:my_app, :key, 1)
        def b, do: Application.get_env(:mob, :plugins, [])
      end
      """)

      assert %{findings: []} = Audit.audit_plugin(dir, %{name: :x})
    end
  end

  describe "audit_plugin/2 — file / network I/O" do
    test "flags File.write/rm_rf/cp", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def a(p), do: File.write(p, "x")
        def b(p), do: File.rm_rf!(p)
        def c(a, b), do: File.cp(a, b)
      end
      """)

      assert %{findings: findings} = Audit.audit_plugin(dir, %{name: :x})
      assert length(findings) == 3
      assert Enum.all?(findings, &(&1.severity == :medium and &1.rule == :file_io))
    end

    test "flags :os.cmd and System.cmd", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def a, do: :os.cmd(~c"ls")
        def b, do: System.cmd("ls", [])
      end
      """)

      assert %{findings: findings} = Audit.audit_plugin(dir, %{name: :x})
      assert length(findings) == 2
      assert Enum.all?(findings, &(&1.rule == :process_spawn))
    end

    test "flags Path.expand(\"~\")", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def home, do: Path.expand("~")
      end
      """)

      assert %{findings: [f]} = Audit.audit_plugin(dir, %{name: :x})
      assert f.rule == :home_escape
    end

    test "does NOT flag Path.expand on a non-home string", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def p(x), do: Path.expand("./foo", x)
      end
      """)

      assert %{findings: []} = Audit.audit_plugin(dir, %{name: :x})
    end
  end

  describe "audit_plugin/2 — C NIF sources" do
    setup %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native/jni"))
      {:ok, dir: dir}
    end

    test "flags system(), popen(), execve()", %{dir: dir} do
      write_file(dir, "priv/native/jni/a.c", """
      #include <stdlib.h>
      void a(void) { system("rm -rf /"); }
      void b(void) { popen("ls", "r"); }
      void c(void) { execve("/bin/sh", 0, 0); }
      """)

      assert %{findings: findings} = Audit.audit_plugin(dir, %{name: :x})
      assert length(findings) == 3
      assert Enum.all?(findings, &(&1.severity == :high and &1.rule == :process_spawn))
    end

    test "flags raw socket() creation as medium", %{dir: dir} do
      write_file(dir, "priv/native/jni/n.c", """
      int n(void) { return socket(2, 1, 0); }
      """)

      assert %{findings: [f]} = Audit.audit_plugin(dir, %{name: :x})
      assert f.severity == :medium
      assert f.rule == :raw_socket
    end

    test "does NOT flag system() that appears only in a // comment", %{dir: dir} do
      write_file(dir, "priv/native/jni/c.c", """
      // intentionally does NOT call system(3) or popen(3).
      int ok(void) { return 0; }
      """)

      assert %{findings: []} = Audit.audit_plugin(dir, %{name: :x})
    end

    test "does NOT flag system() that appears only in a /* */ comment", %{dir: dir} do
      write_file(dir, "priv/native/jni/c.c", """
      /* The NIF deliberately avoids system() and popen() — see audit. */
      int ok(void) { return 0; }
      """)

      assert %{findings: []} = Audit.audit_plugin(dir, %{name: :x})
    end
  end

  describe "audit_plugin/2 — Kotlin/Swift skip" do
    test "reports kotlin_or_swift_skipped: true when present", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "priv/native/android"))
      write_file(dir, "priv/native/android/X.kt", "class X {}\n")
      assert %{kotlin_or_swift_skipped: true} = Audit.audit_plugin(dir, %{name: :x})
    end

    test "reports false when only Elixir and C are present", %{dir: dir} do
      assert %{kotlin_or_swift_skipped: false} = Audit.audit_plugin(dir, %{name: :x})
    end
  end

  describe "tally/1 and exit_code/2" do
    test "tally counts findings per severity" do
      findings = [
        %{severity: :high},
        %{severity: :high},
        %{severity: :medium},
        %{severity: :low},
        %{severity: :low},
        %{severity: :low}
      ]

      assert %{high: 2, medium: 1, low: 3} = Audit.tally(findings)
    end

    test "exit_code/2 — empty reports → 0" do
      assert Audit.exit_code([]) == 0
    end

    test "exit_code/2 — only lows → 0" do
      assert Audit.exit_code([report(0, 0, 3)]) == 0
    end

    test "exit_code/2 — medium without --accept-medium → 1" do
      assert Audit.exit_code([report(0, 2, 0)], false) == 1
    end

    test "exit_code/2 — medium with --accept-medium → 0" do
      assert Audit.exit_code([report(0, 2, 0)], true) == 0
    end

    test "exit_code/2 — high beats medium and --accept-medium → 2" do
      assert Audit.exit_code([report(1, 5, 0)], true) == 2
    end
  end

  describe "audit_plugin/2 — sorting" do
    test "findings are sorted high → medium → low, then by file + line", %{dir: dir} do
      write_ex(dir, "lib/m.ex", """
      defmodule X do
        def a(x), do: String.to_atom(x)
        def b(s), do: Code.eval_string(s)
      end
      """)

      assert %{findings: [f1, f2]} = Audit.audit_plugin(dir, %{name: :x})
      assert f1.severity == :high
      assert f2.severity == :medium
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp write_ex(dir, rel, source) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp write_file(dir, rel, source) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp report(high, medium, low) do
    %{
      plugin: :stub,
      findings: [],
      summary: %{high: high, medium: medium, low: low},
      kotlin_or_swift_skipped: false
    }
  end
end

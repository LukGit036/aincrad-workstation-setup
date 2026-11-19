# Aincrad Workstation Setup

Instalador local para preparar um novo computador Windows com os programas de desenvolvimento e automações do usuário.

## Instalação em uma linha

Abra o PowerShell e execute:

```powershell
$ErrorActionPreference='Stop'; $p=Join-Path $env:TEMP 'aincrad-workstation-install.ps1'; Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/LukGit036/aincrad-workstation-setup/main/install.ps1' -OutFile $p; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
```

O arquivo é baixado e executado como um script `.ps1`. Não use `irm ... | iex`: o instalador tem parâmetros de script (`CmdletBinding`/`param`) e o `Invoke-Expression` não os interpreta corretamente.

O instalador instalará VS Code, Git, GitHub CLI, Node.js LTS, Python, uv, FFmpeg, Streamlink, Obsidian, Antigravity, Claude, Gemini CLI, Codex CLI e Kimi. Depois, abrirá a autenticação do GitHub para restaurar os repositórios privados do usuário.

Ele restaura o cofre `Alice Síntese`, o snapshot Obsidian `Aincrad`, o repositório privado de automações `claude-setup` e o projeto `Underworld-Workspace` com o snapshot `graphify-out`. Configura MCPVault para os dois cofres, executa o instalador de skills/MCPs já versionado e instala `ai-memory` e Graphify para Claude Code, Codex, Gemini CLI, Antigravity e Kimi.

## Testar o plano sem alterar o computador

Baixe este repositório e rode `install.ps1 -PlanOnly`. O modo de plano lista o que seria instalado, sem instalar apps, clonar repositórios ou alterar configurações.

## Segurança e limites

- Este repositório é público e contém somente o instalador. Cofres, projeto e automações ficam em repositórios privados do GitHub.
- A chave da NVIDIA, tokens, sessões do navegador e logins não são publicados nem copiados do PC antigo. O instalador permite informar uma chave NVIDIA no computador novo e salvá-la protegida pelo DPAPI do Windows para o usuário local.
- O usuário precisa autenticar novamente no GitHub e entrar nas contas das ferramentas de IA no novo computador.
- O instalador preserva pastas existentes; quando encontra conteúdo sem Git no destino, usa uma nova pasta com sufixo de restauração.
- Alguns pacotes do WinGet podem variar conforme a versão do Windows. O instalador continua após uma falha e lista no final os itens que precisam de nova tentativa.

Os comandos e integrações usam as fontes oficiais do [ai-memory](https://github.com/akitaonrails/ai-memory), [Graphify](https://github.com/Graphify-Labs/graphify), [MCPVault](https://github.com/bitbonsai/mcpvault) e [Kimi Code](https://moonshotai.github.io/kimi-code/en/guides/getting-started.html).

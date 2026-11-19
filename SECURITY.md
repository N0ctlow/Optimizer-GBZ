# Segurança

## Como reportar um problema de segurança

Se você encontrar algo no Optimizer GBZ que possa causar dano ao sistema ou aos dados de alguém,
**não abra uma issue pública**. Use a aba **Security → Report a vulnerability** deste repositório
para avisar de forma privada.

## O que o script faz no seu PC

- Lê informações do sistema (CPU, RAM, disco, rede) para mostrar no painel.
- Altera configurações do Windows **somente quando você liga um interruptor ou clica num botão**.
- Apaga arquivos **somente** nas pastas listadas na aba Limpeza, com trava contra pastas do sistema.
- Guarda as suas preferências em `HKCU\Software\OptimizerGBZ`.
- Não baixa nem executa código da internet por conta própria.

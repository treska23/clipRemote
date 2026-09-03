# ClipRemote

Control remoto dedicado para **Clip Studio Paint**, pensado especialmente para animación.

El desarrollo se hará en el PC principal y el agente de Windows se publicará como ejecutable autocontenido para poder copiarlo después a la Surface sin instalar Visual Studio ni el SDK de .NET.

## Objetivo

```text
Oppo Android
    ⇅ Wi‑Fi local
ClipRemote.Agent (Windows)
    ⇅ atajos / automatización local
Clip Studio Paint
```

El móvil no será un mando genérico ni un asistente de voz: será una superficie táctil específica para trabajar más rápido en Clip Studio.

## Principios

- Sin nube.
- Sin cuentas.
- Sin API de pago.
- Sin IPs o rutas de un PC codificadas a fuego.
- Comunicación únicamente por red local.
- Respuesta inmediata.
- Emparejamiento sencillo entre el Oppo y el PC.
- El agente de Windows debe poder trasladarse del PC de desarrollo a la Surface.
- Las acciones de Clip Studio se basarán principalmente en atajos configurables, no en coordenadas de pantalla frágiles.

## Estructura

```text
clipRemote/
├─ src/
│  └─ ClipRemote.Agent/       # Agente Windows WPF/.NET
├─ mobile/
│  └─ ClipRemote.Mobile/      # Aplicación Android para el Oppo
├─ docs/
│  ├─ architecture.md
│  └─ protocol.md
├─ ClipRemote.sln
└─ README.md
```

## Primera fase

1. Agente Windows con servidor WebSocket local.
2. Cliente Android capaz de conectarse al agente.
3. Mensaje `action` con identificador de acción.
4. El agente traduce la acción a un atajo de teclado.
5. Primer perfil específico de animación para Clip Studio.

## Primeras acciones de animación

Candidatas para el primer panel:

- Play / Stop.
- Fotograma anterior / siguiente.
- Crear nuevo cel.
- Duplicar cel.
- Onion skin.
- Deshacer / rehacer.
- Zoom y rotación del lienzo.
- Navegación rápida por la línea de tiempo.

Los atajos definitivos se configurarán después según la instalación real de Clip Studio en la Surface.

## Portabilidad a Surface

El agente se publicará como `win-x64` autocontenido:

```powershell
dotnet publish .\src\ClipRemote.Agent\ClipRemote.Agent.csproj -c Release -r win-x64 --self-contained true
```

La carpeta resultante podrá copiarse directamente a la Surface.

# Arquitectura

## Objetivo

ClipRemote separa completamente el desarrollo del equipo donde se usará finalmente.

- El código se desarrolla y compila en el PC principal.
- `ClipRemote.Agent` se publica como aplicación Windows autocontenida.
- La carpeta publicada se copia a la Surface.
- El Oppo se empareja con el PC que esté ejecutando el agente.

## Componentes

### ClipRemote.Agent

Aplicación WPF/.NET que:

- abre un servidor HTTP/WebSocket en la red local;
- genera un token local de emparejamiento;
- recibe identificadores de acciones, nunca código arbitrario;
- traduce cada acción a un atajo configurado en `%LOCALAPPDATA%\ClipRemote\settings.json`;
- solo inyecta teclas si una ventana de `CLIP STUDIO PAINT` está en primer plano.

### ClipRemote.Mobile

Aplicación Android dedicada al Oppo. Tendrá:

- perfiles de PC emparejados;
- panel específico de animación;
- conexión WebSocket persistente mientras esté en uso;
- botones grandes y respuesta visual inmediata;
- más adelante, controles continuos para timeline/zoom si resultan útiles.

## Seguridad

El servidor no acepta acciones sin el header `X-ClipRemote-Token` correcto.

El token se genera localmente y no se guarda en Git.

Aunque un cliente esté autenticado, solo puede pedir IDs existentes en el catálogo local de acciones. El protocolo no permite enviar PowerShell, rutas, ejecutables ni secuencias de teclas arbitrarias.

## Portabilidad

La configuración es local a cada PC. Al mover el agente a la Surface, la Surface generará su propio `settings.json` y token. El Oppo podrá guardar ambos PCs como perfiles distintos durante las pruebas.

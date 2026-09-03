# Protocolo local

## Transporte

WebSocket sobre la red local:

```text
ws://<ip-del-pc>:5057/ws
```

El cliente debe enviar el token en el header:

```text
X-ClipRemote-Token: <token>
```

El token aparece en la ventana del Agent y se guarda únicamente en el PC.

## Acción

El móvil envía únicamente un identificador de acción:

```json
{
  "type": "action",
  "action": "undo"
}
```

Respuesta:

```json
{
  "success": true,
  "message": "Hecho.",
  "action": "undo"
}
```

Si la acción no tiene atajo configurado:

```json
{
  "success": false,
  "message": "Esta acción todavía no tiene un atajo configurado.",
  "action": "playPause"
}
```

## Catálogo inicial

```text
undo
redo
playPause
previousFrame
nextFrame
newCel
duplicateCel
onionSkin
```

El catálogo podrá crecer, pero el móvil nunca envía combinaciones de teclado arbitrarias. El mapeo vive en `settings.json` del Agent.

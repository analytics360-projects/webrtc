const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const path = require('path');

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// Servir archivos estáticos
app.use(express.static(path.join(__dirname, 'public')));

// Estructura para manejar múltiples salas
// rooms = { roomId: { broadcaster: ws, viewers: Set } }
const rooms = {};

wss.on('connection', (ws, req) => {
    const clientIp = req.socket.remoteAddress;
    console.log(`[${new Date().toISOString()}] Nueva conexión WebSocket desde: ${clientIp}`);

    ws.on('message', (message) => {
        const data = JSON.parse(message);
        console.log(`[${new Date().toISOString()}] Mensaje recibido:`, data.type, data.roomId ? `sala: ${data.roomId}` : '');

        switch (data.type) {
            case 'broadcaster':
                handleBroadcaster(ws, data.roomId);
                break;

            case 'viewer':
                handleViewer(ws, data.roomId);
                break;

            case 'offer':
                handleOffer(ws, data);
                break;

            case 'answer':
                handleAnswer(ws, data);
                break;

            case 'ice-candidate':
                handleIceCandidate(ws, data);
                break;

            case 'request-stream':
                handleRequestStream(ws);
                break;

            case 'get-room-info':
                sendRoomInfo(ws, data.roomId);
                break;
        }
    });

    ws.on('close', () => {
        handleDisconnect(ws);
    });

    ws.on('error', (error) => {
        console.error('Error WebSocket:', error);
    });
});

function handleBroadcaster(ws, roomId) {
    if (!roomId) {
        roomId = generateId();
    }

    console.log(`[BROADCASTER] ========================================`);
    console.log(`[BROADCASTER] Nuevo broadcaster intentando conectar`);
    console.log(`[BROADCASTER] Room ID solicitado: ${roomId}`);
    console.log(`[BROADCASTER] Timestamp: ${new Date().toISOString()}`);

    // Verificar si la sala ya tiene un broadcaster
    if (rooms[roomId] && rooms[roomId].broadcaster) {
        console.log(`[BROADCASTER] ERROR: Sala ${roomId} ya tiene broadcaster activo`);
        ws.send(JSON.stringify({
            type: 'error',
            message: 'Esta sala ya tiene un transmisor activo'
        }));
        return;
    }

    // Crear sala si no existe
    if (!rooms[roomId]) {
        rooms[roomId] = { broadcaster: null, viewers: new Set() };
        console.log(`[BROADCASTER] Nueva sala creada: ${roomId}`);
    }

    rooms[roomId].broadcaster = ws;
    ws.role = 'broadcaster';
    ws.roomId = roomId;

    console.log(`[BROADCASTER] Broadcaster conectado exitosamente a sala: ${roomId}`);
    console.log(`[BROADCASTER] Viewers esperando en sala: ${rooms[roomId].viewers.size}`);
    console.log(`[BROADCASTER] ========================================`);

    // Enviar confirmación con el roomId
    ws.send(JSON.stringify({
        type: 'room-created',
        roomId: roomId,
        viewerCount: rooms[roomId].viewers.size
    }));

    // Notificar a los viewers existentes que hay broadcaster
    rooms[roomId].viewers.forEach(viewer => {
        viewer.send(JSON.stringify({ type: 'broadcaster-available' }));
    });
}

function handleViewer(ws, roomId) {
    console.log(`[VIEWER] ========================================`);
    console.log(`[VIEWER] Nuevo viewer intentando conectar`);
    console.log(`[VIEWER] Room ID: ${roomId}`);

    if (!roomId) {
        console.log(`[VIEWER] ERROR: No se proporciono room ID`);
        ws.send(JSON.stringify({
            type: 'error',
            message: 'Se requiere un ID de sala'
        }));
        return;
    }

    // Crear sala si no existe
    if (!rooms[roomId]) {
        rooms[roomId] = { broadcaster: null, viewers: new Set() };
        console.log(`[VIEWER] Sala ${roomId} creada (sin broadcaster)`);
    }

    rooms[roomId].viewers.add(ws);
    ws.role = 'viewer';
    ws.roomId = roomId;

    console.log(`[VIEWER] Viewer conectado a sala: ${roomId}`);
    console.log(`[VIEWER] Total viewers en sala: ${rooms[roomId].viewers.size}`);
    console.log(`[VIEWER] Broadcaster presente: ${!!rooms[roomId].broadcaster}`);

    // Si hay broadcaster, notificar al viewer
    if (rooms[roomId].broadcaster && rooms[roomId].broadcaster.readyState === WebSocket.OPEN) {
        console.log(`[VIEWER] Notificando al viewer que broadcaster esta disponible`);
        ws.send(JSON.stringify({ type: 'broadcaster-available' }));
    } else {
        console.log(`[VIEWER] Viewer esperando broadcaster`);
        ws.send(JSON.stringify({ type: 'waiting-broadcaster' }));
    }
    console.log(`[VIEWER] ========================================`);
}

function handleOffer(ws, data) {
    const roomId = ws.roomId;
    console.log(`[OFFER] Recibido offer del broadcaster en sala: ${roomId} para viewer: ${data.viewerId}`);

    if (!roomId || !rooms[roomId]) {
        console.log(`[OFFER] ERROR: Sala no existe`);
        return;
    }

    const targetViewer = Array.from(rooms[roomId].viewers).find(v => v.viewerId === data.viewerId);
    if (targetViewer) {
        console.log(`[OFFER] Enviando offer al viewer ${data.viewerId}`);
        console.log(`[OFFER] SDP type: ${data.sdp?.type}`);
        targetViewer.send(JSON.stringify({
            type: 'offer',
            sdp: data.sdp
        }));
    } else {
        console.log(`[OFFER] ERROR: Viewer ${data.viewerId} no encontrado`);
    }
}

function handleAnswer(ws, data) {
    const roomId = ws.roomId;
    console.log(`[ANSWER] Recibido answer del viewer ${ws.viewerId} en sala: ${roomId}`);

    if (!roomId || !rooms[roomId] || !rooms[roomId].broadcaster) {
        console.log(`[ANSWER] ERROR: Sala o broadcaster no existe`);
        return;
    }

    console.log(`[ANSWER] Enviando answer al broadcaster`);
    console.log(`[ANSWER] SDP type: ${data.sdp?.type}`);
    rooms[roomId].broadcaster.send(JSON.stringify({
        type: 'answer',
        sdp: data.sdp,
        viewerId: ws.viewerId
    }));
}

function handleIceCandidate(ws, data) {
    const roomId = ws.roomId;
    if (!roomId || !rooms[roomId]) {
        console.log(`[ICE] ERROR: Sala no existe para ICE candidate`);
        return;
    }

    if (ws.role === 'broadcaster') {
        console.log(`[ICE] Broadcaster -> Viewer ${data.viewerId}`);
        const targetViewer = Array.from(rooms[roomId].viewers).find(v => v.viewerId === data.viewerId);
        if (targetViewer) {
            targetViewer.send(JSON.stringify({
                type: 'ice-candidate',
                candidate: data.candidate
            }));
        } else {
            console.log(`[ICE] ERROR: Viewer ${data.viewerId} no encontrado`);
        }
    } else if (ws.role === 'viewer' && rooms[roomId].broadcaster) {
        console.log(`[ICE] Viewer ${ws.viewerId} -> Broadcaster`);
        rooms[roomId].broadcaster.send(JSON.stringify({
            type: 'ice-candidate',
            candidate: data.candidate,
            viewerId: ws.viewerId
        }));
    }
}

function handleRequestStream(ws) {
    const roomId = ws.roomId;
    console.log(`[REQUEST-STREAM] Viewer solicita stream de sala: ${roomId}`);

    if (!roomId || !rooms[roomId] || !rooms[roomId].broadcaster) {
        console.log(`[REQUEST-STREAM] ERROR: Sala o broadcaster no disponible`);
        return;
    }

    ws.viewerId = generateId();
    console.log(`[REQUEST-STREAM] Viewer ID asignado: ${ws.viewerId}`);
    console.log(`[REQUEST-STREAM] Notificando al broadcaster sobre nuevo viewer`);

    rooms[roomId].broadcaster.send(JSON.stringify({
        type: 'viewer-joined',
        viewerId: ws.viewerId
    }));

    // Notificar al broadcaster la cantidad de viewers
    updateViewerCount(roomId);
}

function handleDisconnect(ws) {
    const roomId = ws.roomId;
    if (!roomId || !rooms[roomId]) return;

    if (ws.role === 'broadcaster') {
        console.log(`Broadcaster desconectado de sala: ${roomId}`);

        // Notificar a todos los viewers
        rooms[roomId].viewers.forEach(viewer => {
            viewer.send(JSON.stringify({ type: 'broadcaster-disconnected' }));
        });

        rooms[roomId].broadcaster = null;

        // Si no hay viewers, eliminar la sala
        if (rooms[roomId].viewers.size === 0) {
            delete rooms[roomId];
            console.log(`Sala eliminada: ${roomId}`);
        }
    } else if (ws.role === 'viewer') {
        rooms[roomId].viewers.delete(ws);
        console.log(`Viewer desconectado de sala: ${roomId}. Total viewers: ${rooms[roomId].viewers.size}`);

        // Notificar al broadcaster
        if (rooms[roomId].broadcaster && rooms[roomId].broadcaster.readyState === WebSocket.OPEN) {
            rooms[roomId].broadcaster.send(JSON.stringify({
                type: 'viewer-left',
                viewerId: ws.viewerId
            }));
            updateViewerCount(roomId);
        }

        // Si no hay broadcaster ni viewers, eliminar la sala
        if (!rooms[roomId].broadcaster && rooms[roomId].viewers.size === 0) {
            delete rooms[roomId];
            console.log(`Sala eliminada: ${roomId}`);
        }
    }
}

function updateViewerCount(roomId) {
    if (!rooms[roomId] || !rooms[roomId].broadcaster) return;

    rooms[roomId].broadcaster.send(JSON.stringify({
        type: 'viewer-count',
        count: rooms[roomId].viewers.size
    }));
}

function sendRoomInfo(ws, roomId) {
    if (!roomId) {
        ws.send(JSON.stringify({ type: 'room-info', exists: false }));
        return;
    }

    const room = rooms[roomId];
    ws.send(JSON.stringify({
        type: 'room-info',
        exists: !!room,
        hasBroadcaster: room ? !!room.broadcaster : false,
        viewerCount: room ? room.viewers.size : 0
    }));
}

function generateId() {
    return Math.random().toString(36).substring(2, 10).toUpperCase();
}

// API REST para obtener info de salas
app.get('/api/rooms', (req, res) => {
    const roomList = Object.keys(rooms).map(roomId => ({
        roomId,
        hasBroadcaster: !!rooms[roomId].broadcaster,
        viewerCount: rooms[roomId].viewers.size
    }));
    res.json(roomList);
});

app.get('/api/rooms/:roomId', (req, res) => {
    const room = rooms[req.params.roomId];
    if (!room) {
        return res.status(404).json({ error: 'Sala no encontrada' });
    }
    res.json({
        roomId: req.params.roomId,
        hasBroadcaster: !!room.broadcaster,
        viewerCount: room.viewers.size
    });
});

const PORT = process.env.PORT || 9010;
server.listen(PORT, () => {
    console.log(`Servidor WebRTC ejecutándose en http://localhost:${PORT}`);
    console.log(`- Broadcaster: http://localhost:${PORT}/broadcaster.html`);
    console.log(`- Viewer: http://localhost:${PORT}/viewer.html?room=ROOM_ID`);
});

# Create-AiSaaS.ps1
# Run this in PowerShell to generate the entire AI Enterprise SaaS codebase

$ProjectRoot = "$env:USERPROFILE\Desktop\AiEnterpriseSaaS"
Write-Host "Creating project at $ProjectRoot" -ForegroundColor Green

# Create directories
New-Item -ItemType Directory -Force -Path "$ProjectRoot\backend" | Out-Null
New-Item -ItemType Directory -Force -Path "$ProjectRoot\frontend\src" | Out-Null
New-Item -ItemType Directory -Force -Path "$ProjectRoot\frontend\public" | Out-Null

# ------------------- BACKEND FILES -------------------

# requirements.txt
@"
fastapi==0.104.1
uvicorn==0.24.0
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
groq==0.4.2
python-multipart==0.0.6
PyPDF2==3.0.1
python-dotenv==1.0.0
# For SQLite no extra driver needed
# If using SQL Server, uncomment: pyodbc==5.0.1
"@ | Out-File -FilePath "$ProjectRoot\backend\requirements.txt" -Encoding utf8

# .env (template)
@"
GROQ_API_KEY=your_groq_api_key_here
SECRET_KEY=change_this_to_a_long_random_string
ALGORITHM=HS256
ACCESS_EXPIRE_MINUTES=30
REFRESH_EXPIRE_DAYS=7
"@ | Out-File -FilePath "$ProjectRoot\backend\.env" -Encoding utf8

# db.py (SQLite version - lightweight, no hang)
@"
import sqlite3
import os

DB_PATH = os.path.join(os.path.dirname(__file__), 'aiapp.db')

def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with get_conn() as conn:
        conn.execute('''
            CREATE TABLE IF NOT EXISTS Users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                email TEXT UNIQUE,
                password_hash TEXT,
                role TEXT DEFAULT 'user'
            )
        ''')
        conn.execute('''
            CREATE TABLE IF NOT EXISTS Chats (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                message TEXT,
                response TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        conn.execute('''
            CREATE TABLE IF NOT EXISTS Files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                filename TEXT,
                content TEXT,
                uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
# Call init_db() once at startup - will be done in main.py
"@ | Out-File -FilePath "$ProjectRoot\backend\db.py" -Encoding utf8

# auth.py
@"
from jose import jwt
from datetime import datetime, timedelta
from passlib.context import CryptContext
from db import get_conn
import os
from dotenv import load_dotenv

load_dotenv()

SECRET_KEY = os.getenv("SECRET_KEY")
ALGORITHM = os.getenv("ALGORITHM")
ACCESS_EXPIRE_MINUTES = int(os.getenv("ACCESS_EXPIRE_MINUTES", 30))
REFRESH_EXPIRE_DAYS = int(os.getenv("REFRESH_EXPIRE_DAYS", 7))

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def hash_password(password):
    return pwd_context.hash(password)

def verify_password(password, hashed):
    return pwd_context.verify(password, hashed)

def create_access_token(data: dict):
    payload = data.copy()
    payload.update({"exp": datetime.utcnow() + timedelta(minutes=ACCESS_EXPIRE_MINUTES)})
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)

def create_refresh_token(data: dict):
    payload = data.copy()
    payload.update({"exp": datetime.utcnow() + timedelta(days=REFRESH_EXPIRE_DAYS)})
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)

def register_user(email, password):
    conn = get_conn()
    cur = conn.cursor()
    hashed = hash_password(password)
    try:
        cur.execute("INSERT INTO Users (email, password_hash) VALUES (?, ?)", (email, hashed))
        conn.commit()
        return True
    except Exception:
        return False
    finally:
        conn.close()

def authenticate_user(email, password):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("SELECT id, password_hash, role FROM Users WHERE email = ?", (email,))
    user = cur.fetchone()
    conn.close()
    if not user:
        return None
    if not verify_password(password, user["password_hash"]):
        return None
    return {"id": user["id"], "role": user["role"]}
"@ | Out-File -FilePath "$ProjectRoot\backend\auth.py" -Encoding utf8

# ai.py
@"
from groq import Groq
import os

client = Groq(api_key=os.getenv("GROQ_API_KEY"))

def stream_ai_response(messages):
    response = client.chat.completions.create(
        model="llama-3.1-8b-instant",
        messages=messages,
        stream=True,
        temperature=0.7
    )
    for chunk in response:
        if chunk.choices[0].delta.content:
            yield chunk.choices[0].delta.content

def get_ai_response(messages):
    response = client.chat.completions.create(
        model="llama-3.1-8b-instant",
        messages=messages
    )
    return response.choices[0].message.content
"@ | Out-File -FilePath "$ProjectRoot\backend\ai.py" -Encoding utf8

# main.py
@"
from fastapi import FastAPI, Depends, HTTPException, Header, UploadFile, File
from fastapi.responses import StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from jose import jwt, JWTError
import os
from dotenv import load_dotenv

from auth import register_user, authenticate_user, create_access_token, create_refresh_token, SECRET_KEY, ALGORITHM
from ai import stream_ai_response, get_ai_response
from db import get_conn, init_db
from PyPDF2 import PdfReader
import io

load_dotenv()

# Initialize database tables
init_db()

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------- Models ----------
class RegisterRequest(BaseModel):
    email: str
    password: str

class LoginRequest(BaseModel):
    email: str
    password: str

class RefreshRequest(BaseModel):
    refresh_token: str

class ChatRequest(BaseModel):
    message: str

# ---------- Auth helpers ----------
def get_current_user(token: str = Header(None)):
    if token is None:
        raise HTTPException(status_code=401, detail="Missing token")
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id = payload.get("user_id")
        if user_id is None:
            raise HTTPException(status_code=401, detail="Invalid token")
        return user_id
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

def get_current_user_role(user_id: int):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("SELECT role FROM Users WHERE id = ?", (user_id,))
    row = cur.fetchone()
    conn.close()
    return row["role"] if row else None

# ---------- Public endpoints ----------
@app.post("/register")
def register(req: RegisterRequest):
    success = register_user(req.email, req.password)
    if not success:
        raise HTTPException(status_code=400, detail="Email already exists")
    return {"msg": "User created"}

@app.post("/login")
def login(req: LoginRequest):
    user = authenticate_user(req.email, req.password)
    if not user:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    access_token = create_access_token({"user_id": user["id"]})
    refresh_token = create_refresh_token({"user_id": user["id"]})
    return {"access_token": access_token, "refresh_token": refresh_token, "role": user["role"]}

@app.post("/refresh")
def refresh(req: RefreshRequest):
    try:
        payload = jwt.decode(req.refresh_token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id = payload.get("user_id")
        if not user_id:
            raise HTTPException(status_code=401, detail="Invalid refresh token")
        new_access = create_access_token({"user_id": user_id})
        return {"access_token": new_access}
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid refresh token")

# ---------- Protected endpoints ----------
@app.post("/chat")
def chat(req: ChatRequest, user_id: int = Depends(get_current_user)):
    conn = get_conn()
    cur = conn.cursor()
    response_text = get_ai_response([
        {"role": "system", "content": "You are a helpful AI assistant."},
        {"role": "user", "content": req.message}
    ])
    cur.execute("INSERT INTO Chats (user_id, message, response) VALUES (?, ?, ?)",
                (user_id, req.message, response_text))
    conn.commit()
    conn.close()
    return {"response": response_text}

@app.post("/chat-stream")
def chat_stream(req: ChatRequest, user_id: int = Depends(get_current_user)):
    def event_stream():
        full_response = ""
        for token in stream_ai_response([
            {"role": "system", "content": "You are a helpful AI assistant."},
            {"role": "user", "content": req.message}
        ]):
            full_response += token
            yield token
        conn = get_conn()
        cur = conn.cursor()
        cur.execute("INSERT INTO Chats (user_id, message, response) VALUES (?, ?, ?)",
                    (user_id, req.message, full_response))
        conn.commit()
        conn.close()
    return StreamingResponse(event_stream(), media_type="text/plain")

@app.post("/upload-file")
async def upload_file(file: UploadFile = File(...), user_id: int = Depends(get_current_user)):
    if not file.filename.endswith('.pdf'):
        raise HTTPException(status_code=400, detail="Only PDF files allowed")
    contents = await file.read()
    pdf_reader = PdfReader(io.BytesIO(contents))
    text = ""
    for page in pdf_reader.pages:
        text += page.extract_text()
    summary = get_ai_response([
        {"role": "system", "content": "Summarize the following document concisely:"},
        {"role": "user", "content": text[:6000]}
    ])
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("INSERT INTO Files (user_id, filename, content) VALUES (?, ?, ?)",
                (user_id, file.filename, text[:10000]))
    conn.commit()
    conn.close()
    return {"summary": summary, "filename": file.filename}

@app.get("/history")
def get_history(user_id: int = Depends(get_current_user)):
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("SELECT message, response, created_at FROM Chats WHERE user_id = ? ORDER BY created_at DESC", (user_id,))
    rows = cur.fetchall()
    conn.close()
    return [{"message": row["message"], "response": row["response"], "timestamp": row["created_at"]} for row in rows]

@app.get("/admin/users")
def admin_users(user_id: int = Depends(get_current_user)):
    role = get_current_user_role(user_id)
    if role != "admin":
        raise HTTPException(status_code=403, detail="Admin only")
    conn = get_conn()
    cur = conn.cursor()
    cur.execute("SELECT id, email, role FROM Users")
    users = cur.fetchall()
    conn.close()
    return [{"id": u["id"], "email": u["email"], "role": u["role"]} for u in users]

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
"@ | Out-File -FilePath "$ProjectRoot\backend\main.py" -Encoding utf8

# Dockerfile
@"
FROM python:3.10-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
"@ | Out-File -FilePath "$ProjectRoot\backend\Dockerfile" -Encoding utf8

# ------------------- FRONTEND FILES -------------------

# package.json
@"
{
  "name": "ai-saas-frontend",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "axios": "^1.6.0"
  },
  "scripts": {
    "start": "react-scripts start",
    "build": "react-scripts build"
  },
  "devDependencies": {
    "react-scripts": "5.0.1"
  }
}
"@ | Out-File -FilePath "$ProjectRoot\frontend\package.json" -Encoding utf8

# public/index.html
@"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>AI Enterprise SaaS</title>
</head>
<body>
    <div id="root"></div>
</body>
</html>
"@ | Out-File -FilePath "$ProjectRoot\frontend\public\index.html" -Encoding utf8

# src/api.js
@"
import axios from 'axios';

const API = axios.create({
  baseURL: 'http://localhost:8000'
});

API.interceptors.request.use((config) => {
  const token = localStorage.getItem('access_token');
  if (token) {
    config.headers.token = token;
  }
  return config;
});

API.interceptors.response.use(
  (response) => response,
  async (error) => {
    const originalRequest = error.config;
    if (error.response?.status === 401 && !originalRequest._retry) {
      originalRequest._retry = true;
      const refresh = localStorage.getItem('refresh_token');
      if (refresh) {
        try {
          const { data } = await axios.post('http://localhost:8000/refresh', { refresh_token: refresh });
          localStorage.setItem('access_token', data.access_token);
          originalRequest.headers.token = data.access_token;
          return API(originalRequest);
        } catch (e) {
          localStorage.clear();
          window.location.href = '/login';
        }
      }
    }
    return Promise.reject(error);
  }
);

export default API;
"@ | Out-File -FilePath "$ProjectRoot\frontend\src\api.js" -Encoding utf8

# src/App.js
@"
import React, { useState, useEffect } from 'react';
import API from './api';

function App() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loggedIn, setLoggedIn] = useState(false);
  const [message, setMessage] = useState('');
  const [chatHistory, setChatHistory] = useState([]);
  const [isListening, setIsListening] = useState(false);
  const [voiceMode, setVoiceMode] = useState(false);
  const [file, setFile] = useState(null);

  const handleLogin = async (e) => {
    e.preventDefault();
    try {
      const res = await API.post('/login', { email, password });
      localStorage.setItem('access_token', res.data.access_token);
      localStorage.setItem('refresh_token', res.data.refresh_token);
      setLoggedIn(true);
      fetchHistory();
    } catch (err) {
      alert('Login failed');
    }
  };

  const fetchHistory = async () => {
    const res = await API.get('/history');
    setChatHistory(res.data);
  };

  const sendMessage = async (text) => {
    if (!text.trim()) return;
    setMessage('');
    setChatHistory(prev => [...prev, { message: text, response: '...' }]);

    try {
      const response = await fetch('http://localhost:8000/chat-stream', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          token: localStorage.getItem('access_token')
        },
        body: JSON.stringify({ message: text })
      });

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let aiText = '';
      let done = false;

      setChatHistory(prev => {
        const newHistory = [...prev];
        newHistory[newHistory.length - 1] = { message: text, response: '' };
        return newHistory;
      });

      while (!done) {
        const { value, done: readerDone } = await reader.read();
        done = readerDone;
        if (value) {
          const chunk = decoder.decode(value);
          aiText += chunk;
          setChatHistory(prev => {
            const newHistory = [...prev];
            newHistory[newHistory.length - 1].response = aiText;
            return newHistory;
          });
        }
      }

      if (voiceMode && aiText) {
        const utterance = new SpeechSynthesisUtterance(aiText);
        utterance.lang = 'en-US';
        window.speechSynthesis.speak(utterance);
      }
    } catch (err) {
      console.error(err);
    }
  };

  const startVoiceInput = () => {
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      alert('Your browser does not support speech recognition.');
      return;
    }
    const recognition = new SpeechRecognition();
    recognition.lang = 'en-US';
    recognition.interimResults = false;
    recognition.start();
    setIsListening(true);
    recognition.onresult = (event) => {
      const spokenText = event.results[0][0].transcript;
      setMessage(spokenText);
      setIsListening(false);
    };
    recognition.onerror = () => setIsListening(false);
  };

  const uploadFile = async () => {
    if (!file) return;
    const formData = new FormData();
    formData.append('file', file);
    const res = await API.post('/upload-file', formData, {
      headers: { 'Content-Type': 'multipart/form-data' }
    });
    alert(`Summary: ${res.data.summary}`);
    setFile(null);
  };

  if (!loggedIn) {
    return (
      <div style={{ padding: 20 }}>
        <h2>Login</h2>
        <form onSubmit={handleLogin}>
          <input type="email" placeholder="Email" value={email} onChange={e => setEmail(e.target.value)} required /><br/>
          <input type="password" placeholder="Password" value={password} onChange={e => setPassword(e.target.value)} required /><br/>
          <button type="submit">Login</button>
        </form>
        <p>Demo: Register first via API (POST /register) or add register form yourself.</p>
      </div>
    );
  }

  return (
    <div style={{ padding: 20, maxWidth: 800, margin: 'auto' }}>
      <h1>AI Enterprise Assistant</h1>
      <div>
        <button onClick={() => setVoiceMode(!voiceMode)} style={{ marginRight: 10 }}>
          {voiceMode ? '🔊 Voice Output ON' : '🔇 Voice Output OFF'}
        </button>
        <button onClick={startVoiceInput} disabled={isListening}>
          🎤 {isListening ? 'Listening...' : 'Speak'}
        </button>
        <label style={{ marginLeft: 10 }}>
          📄 Upload PDF:
          <input type="file" accept="application/pdf" onChange={e => setFile(e.target.files[0])} />
          <button onClick={uploadFile}>Upload & Summarize</button>
        </label>
      </div>

      <div style={{ marginTop: 20 }}>
        <textarea rows="3" cols="60" value={message} onChange={e => setMessage(e.target.value)} placeholder="Type or speak..." />
        <br />
        <button onClick={() => sendMessage(message)}>Send</button>
      </div>

      <div style={{ marginTop: 30 }}>
        <h3>Chat History</h3>
        {chatHistory.map((chat, idx) => (
          <div key={idx} style={{ borderBottom: '1px solid #ccc', marginBottom: 10 }}>
            <strong>You:</strong> {chat.message}<br />
            <strong>AI:</strong> {chat.response}
          </div>
        ))}
      </div>
    </div>
  );
}

export default App;
"@ | Out-File -FilePath "$ProjectRoot\frontend\src\App.js" -Encoding utf8

# src/index.js
@"
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(<App />);
"@ | Out-File -FilePath "$ProjectRoot\frontend\src\index.js" -Encoding utf8

# README.md
@"
# AI Enterprise SaaS with Voice Assistant

## Setup
1. Get a Groq API key from https://console.groq.com
2. Edit `backend/.env` and put your key
3. Backend: `cd backend`, `pip install -r requirements.txt`, `python main.py`
4. Frontend: `cd frontend`, `npm install`, `npm start`
5. Open http://localhost:3000

## Features
- JWT auth (access + refresh tokens)
- Streaming AI responses
- Voice input (speech-to-text)
- Voice output (text-to-speech)
- PDF upload and AI summarization
- Chat history
- Role-based access (admin)

## Notes
- Uses SQLite by default (lightweight, no extra install)
- Change SECRET_KEY in .env for production
"@ | Out-File -FilePath "$ProjectRoot\README.md" -Encoding utf8

Write-Host "✅ Project created at $ProjectRoot" -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Edit $ProjectRoot\backend\.env and add your GROQ_API_KEY" -ForegroundColor Cyan
Write-Host "2. Open two terminals:" -ForegroundColor Cyan
Write-Host "   - Backend: cd $ProjectRoot\backend ; pip install -r requirements.txt ; python main.py" -ForegroundColor Cyan
Write-Host "   - Frontend: cd $ProjectRoot\frontend ; npm install ; npm start" -ForegroundColor Cyan
Write-Host "3. Register a user via API (use Postman or add a register form in frontend)" -ForegroundColor Yellow

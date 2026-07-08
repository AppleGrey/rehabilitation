# -*- coding: utf-8 -*-
"""
Created on Sun Apr  6 01:50:39 2025

@author: tang
"""

# -*- coding: utf-8 -*-
"""
批量执行：读取 txt 中的问题，使用 RAG 模型获取回答，保存为对应编号的 txt 文件
"""

import os
from lightrag import QueryParam
import os

from lightrag import LightRAG, QueryParam
from lightrag.llm.hf import hf_model_complete, hf_embed
from lightrag.utils import EmbeddingFunc
from transformers import AutoModel, AutoTokenizer


device = 0

os.environ["CUDA_VISIBLE_DEVICES"] = f"{device}" 

WORKING_DIR = "/home/Starla/tangguoling/LightRAG-KF/KangFu-Full-QwQ-32B-AWQ/"

if not os.path.exists(WORKING_DIR):
    os.mkdir(WORKING_DIR)

rag = LightRAG(
    working_dir=WORKING_DIR,
    llm_model_func=hf_model_complete,
    llm_model_name="/mnt/newdisk/liuyong/EEG_VLM/ckpt/QwQ-32B-AWQ/",
    embedding_func=EmbeddingFunc(
        embedding_dim=1024,
        max_token_size=8192,
        func=lambda texts: hf_embed(
            texts,
            tokenizer=AutoTokenizer.from_pretrained(
                "/mnt/newdisk/liuyong/EEG_VLM/ckpt/bge-m3/"
            ),
            embed_model=AutoModel.from_pretrained(
                "/mnt/newdisk/liuyong/EEG_VLM/ckpt/bge-m3/"
            ),
        ),
    ),
)


# with open("./book.txt", "r", encoding="utf-8") as f:
#     rag.insert(f.read())

from docx import Document

# 定义要读取的文件路径
file_paths = [
    "/home/Starla/tangguoling/LightRAG-KF/books-kangfu/Clinical Orthopaedic Rehabilitation A Team Approach.docx",
    "/home/Starla/tangguoling/LightRAG-KF/books-kangfu/Measurement of Joint Motion- A Guide to Goniometry 4th - Norkin, White, Malone.docx",
    "/home/Starla/tangguoling/LightRAG-KF/books-kangfu/OrthopaedicPhysicalTherapySecrets(2nd,2006).docx"
]

# 读取所有文档内容
def read_docx(file_path):
    doc = Document(file_path)
    text = "\n".join([para.text for para in doc.paragraphs])
    return text

# 合并所有文档的内容
all_text = "\n\n".join([read_docx(file) for file in file_paths])

# 插入到 RAG 系统
rag.insert(all_text)

# 设置输出目录
output_folder = "/home/Starla/tangguoling/LightRAG-KF/data/answers"
os.makedirs(output_folder, exist_ok=True)

# 读取问题文件
input_file_path = "/home/Starla/tangguoling/LightRAG-KF/data/question/AI康复师500问_精简版.txt"
with open(input_file_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

## 按格式提取问题（例如 "1. AI康复师你好，XXX？"）
questions = []
for line in lines:
    if "." in line:
        try:
            idx, question = line.strip().split(".", 1)
            questions.append((int(idx.strip()), question.strip()))
        except:
            continue

# 分成四段处理
batches = [
    (1, 125),
    (126, 250),
    (251, 375),
    (376, 500),
]

# 设置当前批次索引（0 到 3，对应第1到第4段）
current_batch_index = device  # ← 你可以修改为 0, 1, 2, 3 来控制处理哪一段

# 获取当前批次的开始和结束索引
start_idx, end_idx = batches[current_batch_index]

# 筛选当前批次内的问题
current_batch_questions = [(idx, q) for idx, q in questions if start_idx <= idx <= end_idx]

# 遍历当前批次的问题，调用 rag 查询并保存回答
for idx, q in current_batch_questions:
    print(f"处理第 {idx} 题：{q}")
    try:
        answer = rag.query(q, param=QueryParam(mode="hybrid"))
        with open(os.path.join(output_folder, f"{idx}-{device}.txt"), "w", encoding="utf-8") as f:
            f.write("问题：" + q + "\n\n回答：" + answer)
    except Exception as e:
        print(f"第 {idx} 题处理出错：{e}")

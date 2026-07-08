import os

from lightrag import LightRAG, QueryParam
from lightrag.llm.hf import hf_model_complete, hf_embed
from lightrag.utils import EmbeddingFunc
from transformers import AutoModel, AutoTokenizer

os.environ["CUDA_VISIBLE_DEVICES"] = "0,1,2,3" 

WORKING_DIR = "./KangFu-Full-QwQ-32B-AWQ"

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



# # Perform naive search
# print(
#     rag.query("A 60-year-old patient sustained a knee injury from a fall and underwent surgery. How should they perform postoperative rehabilitation exercises? 用中文回答", param=QueryParam(mode="naive"))
# )

# # Perform local search
# print(
#     rag.query("A 60-year-old patient sustained a knee injury from a fall and underwent surgery. How should they perform postoperative rehabilitation exercises? 用中文回答", param=QueryParam(mode="local"))
# )

# # Perform global search
# print(
#     rag.query("A 60-year-old patient sustained a knee injury from a fall and underwent surgery. How should they perform postoperative rehabilitation exercises? 用中文回答", param=QueryParam(mode="global"))
# )

# # Perform hybrid search
# print(
#     rag.query("A 60-year-old patient sustained a knee injury from a fall and underwent surgery. How should they perform postoperative rehabilitation exercises? 用中文回答", param=QueryParam(mode="hybrid"))
# )


# # Perform naive search
# print(
#     rag.query("一位60岁的患者因摔倒导致膝关节受伤并接受了手术治疗。术后应如何进行康复锻炼？", param=QueryParam(mode="naive"))
# )

# # Perform local search
# print(
#     rag.query("一位60岁的患者因摔倒导致膝关节受伤并接受了手术治疗。术后应如何进行康复锻炼？", param=QueryParam(mode="local"))
# )

# # Perform global search
# print(
#     rag.query("一位60岁的患者因摔倒导致膝关节受伤并接受了手术治疗。术后应如何进行康复锻炼？", param=QueryParam(mode="global"))
# )

# Perform hybrid search
print(
    rag.query("AI康复师你好，为什么我的关节活动时会发出咔哒声这是否有害？", param=QueryParam(mode="hybrid"))
)

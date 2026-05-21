import json

# ==========================================
# 1. 比赛时：在这里写你的实际业务逻辑函数
# ==========================================


def get_weather(city: str) -> str:
    """模拟查询天气"""
    # 实际比赛中，这里可以发起 requests 请求真实 API
    mock_data = {"北京": "晴，25度", "上海": "雨，20度", "广州": "多云，28度", "深圳": "晴，30度"}
    return mock_data.get(city, f"找不到 {city} 的天气信息")


def query_inventory(product_name: str) -> str:
    """模拟查询数据库库存"""
    # 实际比赛中，这里可以执行 SQL 查询
    if "手机" in product_name:
        return '{"stock": 150, "price": 4999}'
    if "电脑" in product_name or "笔记本" in product_name:
        return '{"stock": 30, "price": 8999}'
    return '{"stock": 0, "price": 0}'


# ==========================================
# 2. 工具注册表：把函数名映射到实际的 Python 函数
# ==========================================
AVAILABLE_TOOLS = {
    "get_weather": get_weather,
    "query_inventory": query_inventory,
}

# ==========================================
# 3. 工具的 JSON Schema：告诉大模型怎么用这些工具
# ==========================================
TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "获取指定城市的天气情况。当用户询问天气时调用此工具。",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {
                        "type": "string",
                        "description": "城市名称，例如：北京、上海"
                    }
                },
                "required": ["city"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "query_inventory",
            "description": "查询指定商品的库存和价格。当用户询问商品是否还有货、或者多少钱时调用。",
            "parameters": {
                "type": "object",
                "properties": {
                    "product_name": {
                        "type": "string",
                        "description": "商品名称，例如：苹果手机"
                    }
                },
                "required": ["product_name"]
            }
        }
    }
]

package app.mulberry6323.quickpaste;

/** 6 篇使用教程，按 quickpaste-ios-prototype.html 的 TUT 文案整理。 */
public final class Tutorials {

    private Tutorials() { }

    public static String[] order() {
        return new String[]{"keyboard", "history", "category", "split", "continuous", "calc"};
    }

    public static String title(String key) {
        if ("keyboard".equals(key)) return "启用键盘与发送";
        if ("history".equals(key)) return "剪贴板历史";
        if ("category".equals(key)) return "常用语与分类";
        if ("split".equals(key)) return "拆分选词";
        if ("continuous".equals(key)) return "连续复制与悬浮窗";
        if ("calc".equals(key)) return "键盘计算器";
        return "教程";
    }

    public static String summary(String key) {
        if ("keyboard".equals(key)) return "系统设置 → 语言和输入法，启用 QuickPaste，并允许完全访问。";
        if ("history".equals(key)) return "复制文字后，打开 QuickPaste；点记录即可复用。";
        if ("category".equals(key)) return "把常用回复放进分类，在键盘里点一下就输入。";
        if ("split".equals(key)) return "长按历史卡片拆分文字，按点击顺序拼成新句子。";
        if ("continuous".equals(key)) return "点键盘工具条方块按钮，变蓝即开启自动同步。";
        if ("calc".equals(key)) return "点「f(x) 计算」，算出结果后点「输入」。";
        return "";
    }

    /** 每篇的 [小节标题, 正文] 列表 */
    public static String[][] sections(String key) {
        if ("keyboard".equals(key)) {
            return new String[][]{
                {"首次启用", "1. 打开系统「设置」。\n2. 系统 / 其他设置 → 语言和输入法 → 虚拟键盘。\n3. 启用「QuickPaste 同步键盘」，并在输入框切换到它。"},
                {"切换与插入", "在聊天、笔记等 App 中点输入框，长按键盘切换图标选 QuickPaste。点一条剪贴板记录或常用语，即可在光标处插入；连续点多条会依次插入。键盘顶部 🌐 可切下一个键盘。"},
                {"发送后保持展开", "关闭自动收起时，点「发送」只向输入框提交文字，QuickPaste 不会主动收起键盘，你可以继续选内容。"},
                {"发送到电脑", "底行蓝色「发送」把当前输入框文字发回电脑；长按「⋯」打开设置可发剪贴板文字/图片。电脑端会写进 CopyQ 历史。"}
            };
        }
        if ("history".equals(key)) {
            return new String[][]{
                {"保存文字", "在其他 App 复制文字后，切到 QuickPaste 键盘查看。开启「连续复制」后，每次呼出键盘会把系统剪贴板里的新文字收进本机历史。"},
                {"搜索与复制", "在「剪贴板」页上下滚动查找。点记录直接插入输入框；长按可复制到系统剪贴板、发送到电脑、放大图片或删除。"},
                {"整理历史", "置顶内容优先显示，也不受历史保留天数的自动清理影响。删除的记录可在设置 →「最近删除」恢复。"},
                {"电脑同步记录", "电脑 Ctrl+C 的文字和截图约 1 秒后出现在键盘列表，💻 表示电脑复制，📱 表示手机发的。图片显示小缩略图，点开可放大。"}
            };
        }
        if ("category".equals(key)) {
            return new String[][]{
                {"新建分类", "本版本用「置顶」代替分类分组，长按键盘里的条目可置顶。"},
                {"添加常用语", "在「常用语」页长按菜单可编辑；也可在连续复制设置里把抓取内容存到常用语。"},
                {"在键盘中使用", "切换到 QuickPaste 键盘，点顶部「常用语」Tab；点一条即可在光标处插入，连续点多条依次插入。"},
                {"整理与排序", "长按常用语可置顶或删除，置顶内容优先显示。"}
            };
        }
        if ("split".equals(key)) {
            return new String[][]{
                {"进入拆分", "在键盘的剪贴板卡片上长按，选择拆分选词相关操作；文字会被切成多个词块。"},
                {"依次点选", "按顺序点词块，选中的词依次拼进结果框。点错再点一次取消，或点「清空」重新选。"},
                {"插入结果", "点结果框右侧的蓝色上箭头，把拼好的句子插入当前输入框。"},
                {"本版本说明", "键盘版提供长按卡片菜单里的「插入到输入框 / 复制到剪贴板 / 发送到电脑」等核心操作。"}
            };
        }
        if ("continuous".equals(key)) {
            return new String[][]{
                {"先选保存位置", "设置 →「连续复制」中，可选择「剪贴板历史」或「常用语」。"},
                {"开启连续复制", "1. 切到 QuickPaste 键盘。\n2. 点工具条方块按钮 ⧉，变蓝即开启；再点一次关闭。\n3. 切回其他 App 继续复制，回到键盘即可看到记录。"},
                {"确认是否运行", "工具条方块变蓝代表自动同步已开启。"},
                {"重复内容与使用范围", "相同文字会去重处理。连续复制只收集可读取的文字；系统粘贴授权、后台限制和复制速度可能影响保存。"}
            };
        }
        if ("calc".equals(key)) {
            return new String[][]{
                {"开始计算", "点键盘左下角「f(x) 计算」，使用数字、小数点、括号和加减乘除键输入算式，结果随输入更新。"},
                {"把结果用于消息", "有有效结果时点「输入」，仅将计算结果插入当前输入框，并清空当前算式。"},
                {"回到文字列表", "点「返回」退出计算器，算式和结果会清空。"}
            };
        }
        return new String[0][0];
    }
}

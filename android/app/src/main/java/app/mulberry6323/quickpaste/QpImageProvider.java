package app.mulberry6323.quickpaste;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileNotFoundException;

/**
 * 把文件以 content:// 暴露给目标 App：
 *   - 图片 qp_share.png（配合 InputConnection.commitContent 上屏图片）
 *   - v1.8.15 起：cache/qp_export/ 下的导出文件（txt / csv / xlsx），供分享保存
 */
public final class QpImageProvider extends ContentProvider {

    @Override
    public boolean onCreate() {
        return true;
    }

    private File resolve(Uri uri) {
        String name = uri == null ? null : uri.getLastPathSegment();
        if (name == null) return null;
        if ("qp_share.png".equals(name)) {
            return new File(getContext().getFilesDir(), "qp_share.png");
        }
        // 导出文件：仅取文件名，防止目录穿越
        File dir = new File(getContext().getCacheDir(), "qp_export");
        File f = new File(dir, new File(name).getName());
        return f;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        File f = resolve(uri);
        if (f == null || !f.exists()) throw new FileNotFoundException("文件不存在");
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public String getType(Uri uri) {
        String name = uri == null ? null : uri.getLastPathSegment();
        if (name == null) return "application/octet-stream";
        name = name.toLowerCase();
        if (name.endsWith(".png")) return "image/png";
        if (name.endsWith(".txt")) return "text/plain";
        if (name.endsWith(".csv")) return "text/csv";
        if (name.endsWith(".xlsx"))
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        return "application/octet-stream";
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection,
                        String[] selectionArgs, String sortOrder) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}

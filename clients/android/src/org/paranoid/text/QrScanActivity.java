package org.paranoid.text;
import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.hardware.Camera;
import android.os.Bundle;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** Private in-app scanner: no external scanner, URI, upload or persistent camera frame. */
@SuppressWarnings("deprecation")
public final class QrScanActivity extends Activity implements SurfaceHolder.Callback {
    private Camera camera;
    private SurfaceView preview;
    private TextView status;
    private boolean resumed=false,surface=false;
    private final ExecutorService decoder=Executors.newSingleThreadExecutor();
    private final AtomicBoolean busy=new AtomicBoolean();
    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);setResult(RESULT_CANCELED);
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);setContentView(root);
        status=new TextView(this);status.setText("Наведите камеру на публичный QR ParanoID. Снимки не сохраняются.");root.addView(status);
        preview=new SurfaceView(this);root.addView(preview,new LinearLayout.LayoutParams(-1,0,1));preview.getHolder().addCallback(this);
        Button cancel=new Button(this);cancel.setText("Отмена");cancel.setOnClickListener(v->finish());root.addView(cancel);
        if(checkSelfPermission(Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED)requestPermissions(new String[]{Manifest.permission.CAMERA},1);
    }
    @Override public void onResume(){super.onResume();resumed=true;open();}
    @Override public void onPause(){resumed=false;closeCamera();super.onPause();}
    @Override public void onDestroy(){decoder.shutdownNow();super.onDestroy();}
    @Override public void surfaceCreated(SurfaceHolder h){surface=true;open();}
    @Override public void surfaceChanged(SurfaceHolder h,int f,int w,int height){}
    @Override public void surfaceDestroyed(SurfaceHolder h){surface=false;closeCamera();}
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){super.onRequestPermissionsResult(request,permissions,results);if(results.length>0 && results[0]==PackageManager.PERMISSION_GRANTED)open();else status.setText("Камера не разрешена. Отмена сохраняет вашу идентичность; можно вставить публичный код.");}
    private void open(){
        if(!resumed||!surface||camera!=null||checkSelfPermission(Manifest.permission.CAMERA)!=PackageManager.PERMISSION_GRANTED)return;
        try {
            camera=Camera.open();Camera.Parameters p=camera.getParameters();Camera.Size best=null;
            for(Camera.Size s:p.getSupportedPreviewSizes())if(s.width<=1280 && s.height<=1280 && (best==null || Math.abs(s.width*s.height-640*480)<Math.abs(best.width*best.height-640*480)))best=s;
            if(best==null)throw new java.io.IOException("no bounded preview");
            p.setPreviewSize(best.width,best.height);p.setPreviewFormat(android.graphics.ImageFormat.NV21);
            if(p.getSupportedFocusModes().contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE))p.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
            camera.setParameters(p);camera.setDisplayOrientation(90);camera.setPreviewDisplay(preview.getHolder());
            final int width=best.width,height=best.height;
            camera.setPreviewCallback((data,source)->{
                if(!resumed || !busy.compareAndSet(false,true))return;
                if(data==null || data.length>1280*1280*2){busy.set(false);return;}
                byte[] frame=data.clone();
                decoder.execute(()->{
                    String found=null;try{found=QrCodec.decode(frame,width,height);}catch(Exception ignored){}finally{java.util.Arrays.fill(frame,(byte)0);busy.set(false);}
                    final String raw=found;if(raw!=null)runOnUiThread(()->{if(resumed&&!isFinishing()){setResult(RESULT_OK,new Intent().putExtra("public_qr",raw));finish();}});
                });
            });camera.startPreview();
        }catch(Exception error){closeCamera();status.setText("Камера недоступна. Данные не изменены; можно отменить и вставить публичный код.");}
    }
    private void closeCamera(){if(camera!=null){camera.setPreviewCallback(null);camera.stopPreview();camera.release();camera=null;}}
}

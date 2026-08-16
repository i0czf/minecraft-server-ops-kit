package com.chesir.qqaspectindex;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import net.minecraft.core.HolderLookup;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.ReloadableServerResources;
import net.minecraft.server.packs.resources.ResourceManagerReloadListener;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.item.crafting.RecipeManager;
import net.neoforged.fml.ModList;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import net.neoforged.neoforge.event.AddReloadListenerEvent;
import net.neoforged.neoforge.event.server.ServerStartedEvent;
import net.neoforged.neoforge.server.ServerLifecycleHooks;
import net.neoforged.neoforgespi.language.IModFileInfo;
import net.neoforged.neoforgespi.language.IModInfo;
import thaumcraft.api.aspects.Aspect;
import thaumcraft.api.aspects.AspectList;
import thaumcraft.common.aspects.ItemAspectRegistry;

/**
 * 把当前运行中服务端的“物品 -> 要素”结果导出给 QQ 桥。
 *
 * <p>唯一事实源是 Thaumcraft 自己的 ItemAspectRegistry；枚举方式与该版本
 * JEI 的要素来源页一致。没有手抄物品表，也不读取可能残留在 mods 目录里的旧版 JAR。
 */
@Mod(QQAspectIndexMod.MOD_ID)
public final class QQAspectIndexMod {
    public static final String MOD_ID = "qqaspectindex";
    private static final String FORMAT = "qq-item-aspects-v1";
    private static final Object EXPORT_LOCK = new Object();
    private static ExportRequest latestRequest;
    private static boolean workerRunning;
    private static long nextSequence;

    public QQAspectIndexMod() {
        NeoForge.EVENT_BUS.addListener(this::onServerStarted);
        NeoForge.EVENT_BUS.addListener(this::onAddReloadListeners);
    }

    private void onServerStarted(ServerStartedEvent event) {
        MinecraftServer server = event.getServer();
        bindAndRequest(server.getRecipeManager(), server.registryAccess(),
                server.getServerDirectory(), "server-start");
    }

    private void onAddReloadListeners(AddReloadListenerEvent event) {
        ReloadableServerResources resources = event.getServerResources();
        HolderLookup.Provider registries = resources.getRegistryLookup();
        event.addListener((ResourceManagerReloadListener) resourceManager -> {
            MinecraftServer server = ServerLifecycleHooks.getCurrentServer();
            if (server == null)
                return;
            // 此监听器被追加在 RecipeManager 后面；走到这里时 /reload 的新配方已应用。
            bindAndRequest(resources.getRecipeManager(), registries,
                    server.getServerDirectory(), "data-reload");
        });
    }

    private static void bindAndRequest(RecipeManager recipes, HolderLookup.Provider registries,
            Path serverRoot, String trigger) {
        try {
            // 显式绑定很重要：导出在后台线程执行，Thaumcraft 才会使用这份服务端配方快照。
            ItemAspectRegistry.bindRecipeManager(recipes, registries);
            requestExport(serverRoot.toAbsolutePath().normalize(), trigger,
                    recipes.getRecipes().size(), runtimeFingerprint());
        } catch (RuntimeException | LinkageError ex) {
            System.err.println("[qqaspectindex] 无法准备运行时要素索引: " + ex);
        }
    }

    private static void requestExport(Path serverRoot, String trigger,
            int recipeCount, String runtimeFingerprint) {
        boolean startWorker = false;
        synchronized (EXPORT_LOCK) {
            latestRequest = new ExportRequest(++nextSequence, serverRoot, trigger,
                    recipeCount, runtimeFingerprint);
            if (!workerRunning) {
                workerRunning = true;
                startWorker = true;
            }
        }
        if (!startWorker)
            return;
        Thread worker = new Thread(QQAspectIndexMod::runExportLoop, "qq-aspect-index-export");
        worker.setDaemon(true);
        worker.setPriority(Thread.MIN_PRIORITY);
        worker.start();
    }

    private static void runExportLoop() {
        while (true) {
            ExportRequest request;
            synchronized (EXPORT_LOCK) {
                request = latestRequest;
            }

            Path staged = null;
            try {
                staged = buildStagedIndex(request);
                synchronized (EXPORT_LOCK) {
                    if (latestRequest.sequence() == request.sequence()) {
                        publish(staged, request.serverRoot().resolve("tmp").resolve("item-aspects.tsv"));
                        staged = null;
                        workerRunning = false;
                        System.out.println("[qqaspectindex] 运行时物品要素索引已更新，trigger="
                                + request.trigger());
                        return;
                    }
                }
            } catch (Exception | LinkageError ex) {
                System.err.println("[qqaspectindex] 导出运行时物品要素索引失败: " + ex);
                synchronized (EXPORT_LOCK) {
                    if (latestRequest.sequence() == request.sequence()) {
                        workerRunning = false;
                        return;
                    }
                }
            } finally {
                if (staged != null) {
                    try {
                        Files.deleteIfExists(staged);
                    } catch (IOException ignored) {
                    }
                }
            }
            // 导出期间又发生了 /reload：旧结果不发布，直接用最新绑定的配方重新计算。
        }
    }

    private static Path buildStagedIndex(ExportRequest request) throws IOException {
        Map<String, String> zh = loadRuntimeChineseTranslations();
        List<String> aspectRows = new ArrayList<>();
        Aspect.all().values().stream()
                .sorted(Comparator.comparing(Aspect::tag))
                .forEach(aspect -> {
                    String key = "tc.aspect." + aspect.tag();
                    aspectRows.add(String.join("\t",
                            "A",
                            clean(aspect.tag()),
                            clean(key),
                            clean(zh.getOrDefault(key, "")),
                            clean(aspect.displayName().getString()),
                            String.format("%06x", aspect.color() & 0xffffff)));
                });

        List<Item> items = new ArrayList<>();
        BuiltInRegistries.ITEM.forEach(items::add);
        items.sort(Comparator.comparing(item -> BuiltInRegistries.ITEM.getKey(item).toString()));

        List<String> itemRows = new ArrayList<>();
        int failures = 0;
        int registryItems = 0;
        for (Item item : items) {
            if (item == Items.AIR)
                continue;
            registryItems++;
            try {
                // 模组连默认栈构造都可能写坏；也必须按“单物品失败”隔离，不能拖垮整份索引。
                ItemStack stack = item.getDefaultInstance();
                if (stack == null || stack.isEmpty())
                    continue;
                AspectList tags = ItemAspectRegistry.getObjectTags(stack);
                if (tags == null || tags.isEmpty())
                    continue;
                List<String> amounts = new ArrayList<>();
                tags.asMap().entrySet().stream()
                        .filter(entry -> entry.getKey() != null && entry.getValue() != null
                                && entry.getValue() > 0)
                        .sorted(Comparator.comparing(entry -> entry.getKey().tag()))
                        .forEach(entry -> amounts.add(clean(entry.getKey().tag()) + "=" + entry.getValue()));
                if (amounts.isEmpty())
                    continue;
                ResourceLocation id = BuiltInRegistries.ITEM.getKey(item);
                String translationKey = stack.getDescriptionId();
                itemRows.add(String.join("\t",
                        "I",
                        clean(id.toString()),
                        clean(translationKey),
                        clean(zh.getOrDefault(translationKey, "")),
                        clean(stack.getHoverName().getString()),
                        String.join(",", amounts)));
            } catch (RuntimeException | LinkageError ex) {
                failures++;
                if (failures <= 8) {
                    System.err.println("[qqaspectindex] 跳过无法计算的物品 "
                            + BuiltInRegistries.ITEM.getKey(item) + ": " + ex);
                }
            }
        }

        Path outputDir = request.serverRoot().resolve("tmp");
        Files.createDirectories(outputDir);
        Path staged = outputDir.resolve("item-aspects.tsv.part-" + request.sequence());
        try (BufferedWriter out = Files.newBufferedWriter(staged, StandardCharsets.UTF_8)) {
            writeMeta(out, "format", FORMAT);
            writeMeta(out, "generatedAt", Instant.now().toString());
            writeMeta(out, "trigger", request.trigger());
            writeMeta(out, "runtimeFingerprint", request.runtimeFingerprint());
            writeMeta(out, "recipeCount", Integer.toString(request.recipeCount()));
            writeMeta(out, "registryItemCount", Integer.toString(registryItems));
            writeMeta(out, "aspectItemCount", Integer.toString(itemRows.size()));
            writeMeta(out, "failedItemCount", Integer.toString(failures));
            out.write("# A=aspect: tag,translation_key,zh_name,fallback_name,color_rgb\n");
            out.write("# I=item: id,translation_key,zh_name,fallback_name,tag=amount...\n");
            for (String row : aspectRows) {
                out.write(row);
                out.newLine();
            }
            for (String row : itemRows) {
                out.write(row);
                out.newLine();
            }
        }
        return staged;
    }

    private static void writeMeta(BufferedWriter out, String key, String value) throws IOException {
        out.write("# " + key + "=" + clean(value));
        out.newLine();
    }

    private static void publish(Path staged, Path output) throws IOException {
        try {
            Files.move(staged, output, StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE);
        } catch (AtomicMoveNotSupportedException ex) {
            Files.move(staged, output, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private static Map<String, String> loadRuntimeChineseTranslations() {
        Map<String, String> result = new HashMap<>();
        Set<Path> read = new HashSet<>();
        for (IModFileInfo fileInfo : ModList.get().getModFiles()) {
            for (IModInfo mod : fileInfo.getMods()) {
                try {
                    Path path = fileInfo.getFile().findResource(
                            "assets", mod.getNamespace(), "lang", "zh_cn.json");
                    path = path.toAbsolutePath().normalize();
                    if (!Files.isRegularFile(path) || !read.add(path))
                        continue;
                    try (BufferedReader reader = Files.newBufferedReader(path, StandardCharsets.UTF_8)) {
                        JsonElement parsed = JsonParser.parseReader(reader);
                        if (!parsed.isJsonObject())
                            continue;
                        JsonObject object = parsed.getAsJsonObject();
                        for (Map.Entry<String, JsonElement> entry : object.entrySet()) {
                            if (entry.getValue().isJsonPrimitive()
                                    && entry.getValue().getAsJsonPrimitive().isString()) {
                                result.put(entry.getKey(), entry.getValue().getAsString());
                            }
                        }
                    }
                } catch (IOException | RuntimeException ignored) {
                    // 汉化只影响展示名；事实数据仍由 registry id + 要素量完整表达。
                }
            }
        }
        return result;
    }

    private static String runtimeFingerprint() {
        try {
            List<String> parts = new ArrayList<>();
            Set<Path> files = new HashSet<>();
            for (IModInfo mod : ModList.get().getMods()) {
                parts.add("mod:" + mod.getModId() + "=" + mod.getVersion());
                try {
                    files.add(mod.getOwningFile().getFile().getFilePath().toAbsolutePath().normalize());
                } catch (RuntimeException ignored) {
                }
            }
            for (Path file : files) {
                try {
                    parts.add("file:" + file.getFileName() + ":" + Files.size(file) + ":"
                            + Files.getLastModifiedTime(file).toMillis());
                } catch (IOException ex) {
                    parts.add("file:" + file.getFileName() + ":unreadable");
                }
            }
            parts.sort(String::compareTo);
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(String.join("\n", parts).getBytes(StandardCharsets.UTF_8));
            StringBuilder hex = new StringBuilder(hash.length * 2);
            for (byte b : hash)
                hex.append(String.format("%02x", b));
            return hex.toString();
        } catch (Exception ex) {
            return "fingerprint-error";
        }
    }

    private static String clean(String value) {
        if (value == null)
            return "";
        return value.replace('\t', ' ').replace('\r', ' ').replace('\n', ' ').trim();
    }

    private record ExportRequest(long sequence, Path serverRoot, String trigger,
            int recipeCount, String runtimeFingerprint) {
    }
}
